defmodule Workflow.Script do
  @moduledoc """
  Shared workflow script compile gate.

  The loader is path-first but does not trust hand-written reflection functions.
  It parses the script source, extracts the `workflow "name" do ... end` DSL call,
  and runs the same `Workflow.Compiler.parse/2` gate used by the macro.
  """

  alias Workflow.Compiler
  alias Workflow.Compiler.Finding
  alias Workflow.Schema.Compiler, as: SchemaCompiler
  alias Workflow.Script.Error

  @spec load_tree(String.t()) :: {:ok, Workflow.Tree.t()} | {:error, Error.t()}
  def load_tree(path) when is_binary(path) do
    with {:ok, source} <- read(path),
         {:ok, ast} <- quoted(path, source),
         {:ok, name, block, line, schema_bindings} <- workflow_form(path, ast) do
      parse_workflow(path, name, block, line, schema_bindings)
    end
  end

  defp read(path) do
    if File.regular?(path) do
      case File.read(path) do
        {:ok, source} ->
          {:ok, source}

        {:error, reason} ->
          {:error,
           Error.new(
             :compile,
             path,
             "cannot read workflow script: #{:file.format_error(reason)}"
           )}
      end
    else
      {:error, Error.new(:script_not_found, path, "workflow script not found: #{path}")}
    end
  end

  defp quoted(path, source) do
    {:ok, Code.string_to_quoted!(source, file: path, columns: true)}
  rescue
    e in [SyntaxError, TokenMissingError, UnicodeConversionError] ->
      {:error, Error.new(:syntax, path, Exception.message(e))}
  end

  defp workflow_form(path, ast) do
    ast
    |> top_level_forms()
    |> case do
      {:ok, schema_forms, workflow_module} ->
        with {:ok, schema_bindings} <- schema_bindings(path, schema_forms),
             {:ok, forms} <- workflow_module_forms(path, workflow_module) do
          with {:ok, name, block, line} <- extract_workflow(path, forms) do
            {:ok, name, block, line, schema_bindings}
          end
        end

      {:error, message} ->
        {:error, Error.new(:compile, path, message)}
    end
  end

  defp top_level_forms(ast), do: top_level_forms(statements(ast), [], nil)

  defp top_level_forms([], schema_forms, nil) do
    case schema_forms do
      [] ->
        {:error, "cannot compile module: no module defines a workflow"}

      _schema_only ->
        {:error, "cannot compile module: schema definitions require a workflow module"}
    end
  end

  defp top_level_forms([], schema_forms, workflow_module), do: {:ok, Enum.reverse(schema_forms), workflow_module}

  defp top_level_forms([form | rest], schema_forms, workflow_module) do
    cond do
      (schema_import?(form) or schema_form?(form)) and is_nil(workflow_module) ->
        top_level_forms(rest, [form | schema_forms], workflow_module)

      schema_import?(form) or schema_form?(form) ->
        {:error, "cannot compile module: schema definitions must appear before the workflow module"}

      match?({:defmodule, _, _}, form) and is_nil(workflow_module) ->
        top_level_forms(rest, schema_forms, form)

      match?({:defmodule, _, _}, form) ->
        {:error, "cannot compile module: expected exactly one workflow module"}

      true ->
        {:error, top_level_error_message(form)}
    end
  end

  defp workflow_module_forms(path, {:defmodule, _meta, [module, [do: body]]}) do
    forms = statements(body)

    cond do
      not literal_module_alias?(module) ->
        {:error,
         Error.new(
           :compile,
           path,
           "cannot compile module: workflow module name must be a literal alias"
         )}

      Enum.any?(forms, &use_workflow?/1) ->
        {:ok, forms}

      true ->
        {:error, Error.new(:compile, path, "cannot compile module: workflow module must `use Workflow`")}
    end
  end

  defp workflow_module_forms(path, _other),
    do: {:error, Error.new(:compile, path, "cannot compile module: expected a workflow module")}

  defp schema_bindings(_path, []), do: {:ok, %{}}

  defp schema_bindings(path, forms) do
    Enum.reduce_while(forms, {:ok, %{}}, fn
      {:schema, meta, [name, [do: block]]}, {:ok, bindings} ->
        with {:ok, module} <- schema_module(path, name),
             :ok <- available_schema_module(path, module),
             :ok <- unique_schema_module(path, module, bindings),
             {:ok, json} <- parse_schema(path, block, Keyword.get(meta, :line, 1)) do
          {:cont, {:ok, Map.put(bindings, module, json)}}
        else
          {:error, error} -> {:halt, {:error, error}}
        end

      _form, {:ok, bindings} ->
        {:cont, {:ok, bindings}}
    end)
  end

  defp schema_module(path, name) do
    case module_alias(name) do
      {:ok, module} ->
        {:ok, module}

      :error ->
        {:error,
         Error.new(
           :compile,
           path,
           "cannot compile module: schema module name must be a literal alias"
         )}
    end
  end

  defp available_schema_module(path, module) do
    if protected_module?(module) do
      {:error,
       Error.new(
         :compile,
         path,
         "cannot compile module: schema module #{inspect(module)} would redefine an existing module"
       )}
    else
      :ok
    end
  end

  defp unique_schema_module(path, module, bindings) do
    if Map.has_key?(bindings, module) do
      {:error,
       Error.new(
         :compile,
         path,
         "cannot compile module: schema module #{inspect(module)} is defined twice"
       )}
    else
      :ok
    end
  end

  defp parse_schema(path, block, line) do
    env = :elixir.env_for_eval(file: path, line: line)
    {:ok, SchemaCompiler.parse_object(block, env)}
  rescue
    e in [Workflow.CompileError] ->
      {:error, Error.new(:workflow_dsl, path, Exception.message(e))}

    e in [CompileError] ->
      {:error, Error.new(:compile, path, Exception.message(e))}

    e ->
      {:error, Error.new(:compile, path, Exception.message(e))}
  end

  defp extract_workflow(path, forms), do: extract_workflow(path, forms, false, nil)

  defp extract_workflow(_path, [], _workflow_imported?, {:workflow, name, block, line}), do: {:ok, name, block, line}

  defp extract_workflow(path, [], _workflow_imported?, nil) do
    {:error,
     Error.new(:no_workflow, path, "no workflow defined in #{path}", %{
       hint: "define one with `use Workflow` and a `workflow \"name\" do ... end` block"
     })}
  end

  defp extract_workflow(path, [form | rest], workflow_imported?, found) do
    cond do
      use_workflow?(form) ->
        extract_workflow(path, rest, true, found)

      match?({:workflow, _, _}, form) and not workflow_imported? ->
        {:error,
         Error.new(
           :compile,
           path,
           "cannot compile module: workflow declarations must appear after `use Workflow`"
         )}

      match?({:workflow, _, _}, form) and is_nil(found) ->
        with {:ok, workflow} <- workflow_call(path, form) do
          extract_workflow(path, rest, workflow_imported?, workflow)
        end

      match?({:workflow, _, _}, form) ->
        {:error, Error.new(:workflow_dsl, path, "a workflow script may define only one workflow")}

      true ->
        {:error, Error.new(:compile, path, top_level_error_message(form))}
    end
  end

  defp workflow_call(_path, {:workflow, meta, [name, [do: block]]}) when is_binary(name) do
    {:ok, {:workflow, name, block, Keyword.get(meta, :line, 1)}}
  end

  defp workflow_call(path, {:workflow, _meta, [name, _block]}) do
    {:error,
     Error.new(
       :workflow_dsl,
       path,
       "workflow name must be a string literal, got: #{Macro.to_string(name)}"
     )}
  end

  defp workflow_call(path, form) do
    {:error, Error.new(:workflow_dsl, path, "invalid workflow declaration: #{Macro.to_string(form)}")}
  end

  defp parse_workflow(path, name, block, line, schema_bindings) do
    env = :elixir.env_for_eval(file: path, line: line)
    block = inline_schema_bindings(block, schema_bindings)

    case Compiler.parse(block, env) do
      {:ok, tree} ->
        {:ok, %{tree | name: name}}

      {:error, %Finding{} = finding} ->
        {:error, Error.new(:workflow_dsl, path, Finding.format(finding))}
    end
  rescue
    e in [Workflow.CompileError] ->
      {:error, Error.new(:workflow_dsl, path, Exception.message(e))}
  end

  defp top_level_error_message({:raise, _meta, [message]}) when is_binary(message), do: message

  defp top_level_error_message(_form), do: "cannot compile module: unsupported top-level workflow script form"

  defp statements({:__block__, _meta, forms}), do: forms
  defp statements(nil), do: []
  defp statements(form), do: [form]

  defp use_workflow?({:use, _meta, [{:__aliases__, _alias_meta, [:Workflow]}]}), do: true
  defp use_workflow?(_form), do: false

  defp literal_module_alias?(alias_ast), do: match?({:ok, _module}, module_alias(alias_ast))

  defp module_alias({:__aliases__, _meta, parts}) do
    if Enum.all?(parts, &is_atom/1), do: {:ok, Module.concat(parts)}, else: :error
  end

  defp module_alias(_other), do: :error

  defp protected_module?(module) do
    app_module?(module) or Code.ensure_loaded?(module)
  end

  defp app_module?(module), do: String.starts_with?(Atom.to_string(module), "Elixir.Workflow.")

  defp inline_schema_bindings(block, schema_bindings) when map_size(schema_bindings) == 0, do: block

  defp inline_schema_bindings(block, schema_bindings) do
    Macro.prewalk(block, fn
      {:agent, meta, [prompt, opts]} when is_list(opts) ->
        {:agent, meta, [prompt, inline_agent_schema(opts, schema_bindings)]}

      other ->
        other
    end)
  end

  defp inline_agent_schema(opts, schema_bindings) do
    Enum.map(opts, fn
      {:schema, alias_ast} -> {:schema, inline_schema_alias(alias_ast, schema_bindings)}
      other -> other
    end)
  end

  defp inline_schema_alias(alias_ast, schema_bindings) do
    with {:ok, module} <- module_alias(alias_ast),
         {:ok, json} <- Map.fetch(schema_bindings, module) do
      Macro.escape(json)
    else
      _other -> alias_ast
    end
  end

  defp schema_import?({:import, _meta, [{:__aliases__, _alias_meta, [:Workflow, :Schema, :DSL]}]}), do: true

  defp schema_import?(_form), do: false

  defp schema_form?({:schema, _meta, [_name, [do: _block]]}), do: true
  defp schema_form?(_form), do: false
end

defmodule Workflow.Script.Error do
  @moduledoc "Typed expected failures from loading a workflow script."

  @enforce_keys [:kind, :path, :message]
  defstruct [:kind, :path, :message, details: %{}]

  @type kind :: :script_not_found | :no_workflow | :workflow_dsl | :syntax | :compile

  @type t :: %__MODULE__{
          kind: kind(),
          path: String.t(),
          message: String.t(),
          details: map()
        }

  @spec new(kind(), String.t(), String.t(), map()) :: t()
  def new(kind, path, message, details \\ %{}) do
    %__MODULE__{kind: kind, path: path, message: message, details: details}
  end
end
