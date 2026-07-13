defmodule Workflow.Script do
  @moduledoc """
  Loads one path-first workflow declaration into inert `%Workflow.Tree{}` data.

  A script contains exactly one top-level form:

      workflow "demo" do
        phase "prepare"
        agent "Do the work"
        return :ok
      end

  Scripts are parsed as data and are never compiled or evaluated. Source size is
  bounded before parsing, and the tokenizer may only reuse atoms already present
  in the running VM.
  """

  alias Workflow.Compiler
  alias Workflow.Compiler.Finding
  alias Workflow.Script.Error

  @max_source_bytes 1024 * 1024
  @language_modules [
    Compiler,
    Workflow.Predicate,
    Workflow.Refine.Gate,
    Workflow.Refine.ReviewerAdapter,
    Workflow.Template
  ]

  # These author-chosen atoms occur in the workflows shipped with the runtime.
  # Keeping the finite set here makes those scripts self-contained without ever
  # creating an atom from file contents. Other scripts may use any atom that the
  # installed runtime already knows; unknown atoms fail tokenization.
  @shipped_atoms [
    :accept_current,
    :checks,
    :cold_read,
    :correctness,
    :draft,
    :effort,
    :final,
    :id,
    :impact,
    :improved,
    :implementation_fidelity,
    :invariants,
    :items,
    :non_destructiveness,
    :operations,
    :receipt,
    :risk,
    :rows,
    :runtime,
    :safety,
    :spec,
    :spec_completeness,
    :structural_lint,
    :summary,
    :teachability,
    :work
  ]

  @spec load_tree(String.t()) :: {:ok, Workflow.Tree.t()} | {:error, Error.t()}
  def load_tree(path) when is_binary(path) do
    with {:ok, source} <- read(path),
         {:ok, ast} <- quoted(path, source),
         {:ok, name, block, line} <- workflow_form(path, ast) do
      compile(path, name, block, line)
    end
  end

  defp read(path) do
    with {:ok, stat} <- File.stat(path),
         :ok <- regular_file(path, stat),
         :ok <- source_size(path, stat.size),
         {:ok, source} <- File.read(path),
         :ok <- source_size(path, byte_size(source)),
         :ok <- source_encoding(path, source) do
      {:ok, source}
    else
      {:error, %{__struct__: Error} = error} ->
        {:error, error}

      {:error, :enoent} ->
        {:error, Error.new(:script_not_found, path, "workflow script not found: #{path}")}

      {:error, reason} ->
        {:error,
         Error.new(
           :compile,
           path,
           "cannot read workflow script: #{:file.format_error(reason)}"
         )}
    end
  end

  defp regular_file(_path, %{type: :regular}), do: :ok

  defp regular_file(path, _stat), do: {:error, Error.new(:script_not_found, path, "workflow script not found: #{path}")}

  defp source_size(_path, bytes) when bytes <= @max_source_bytes, do: :ok

  defp source_size(path, bytes) do
    {:error,
     Error.new(
       :compile,
       path,
       "workflow script is #{bytes} bytes; maximum is #{@max_source_bytes} bytes"
     )}
  end

  defp source_encoding(path, source) do
    if String.valid?(source) do
      :ok
    else
      {:error, Error.new(:syntax, path, "invalid encoding: workflow script must be valid UTF-8")}
    end
  end

  defp quoted(path, source) do
    # Load the language vocabulary and the bundled workflows' author-chosen atoms
    # before untrusted source reaches the existing-atoms-only tokenizer.
    :ok = Code.ensure_all_loaded(@language_modules)
    :ok = preload_shipped_atoms()

    case Code.string_to_quoted(source,
           file: path,
           columns: true,
           existing_atoms_only: true
         ) do
      {:ok, ast} ->
        {:ok, retain_source_binaries(ast)}

      {:error, {meta, message, token}} ->
        {:error, Error.new(:syntax, path, parser_message(path, meta, message, token))}
    end
  end

  # Consuming this finite literal list at runtime intentionally retains and loads
  # its atoms in a fresh release without converting any source-controlled string.
  defp preload_shipped_atoms do
    Enum.each(@shipped_atoms, fn atom -> true = is_atom(atom) end)
  end

  defp retain_source_binaries(ast) do
    Macro.prewalk(ast, fn
      value when is_binary(value) -> :binary.copy(value)
      node -> node
    end)
  end

  defp parser_message(path, meta, message, token) do
    line = Keyword.get(meta, :line, 1)
    column = Keyword.get(meta, :column, 1)
    "#{path}:#{line}:#{column}: #{message}#{token}"
  end

  defp workflow_form(_path, {:workflow, meta, [name, [do: block]]}) when is_binary(name) do
    {:ok, name, block, Keyword.get(meta, :line, 1)}
  end

  defp workflow_form(path, {:workflow, _meta, [name, _block]}) do
    {:error,
     Error.new(
       :workflow_dsl,
       path,
       "workflow name must be a string literal, got: #{Macro.to_string(name)}"
     )}
  end

  defp workflow_form(path, {:__block__, _meta, []}) do
    {:error,
     Error.new(:no_workflow, path, "no workflow defined in #{path}", %{
       hint: ~s|define exactly one top-level `workflow "name" do ... end` block|
     })}
  end

  defp workflow_form(path, {:__block__, _meta, forms}) when length(forms) > 1 do
    {:error, Error.new(:workflow_dsl, path, "a workflow script must contain exactly one top-level form")}
  end

  defp workflow_form(path, form) do
    {:error,
     Error.new(
       :compile,
       path,
       "unsupported top-level workflow script form: #{Macro.to_string(form)}"
     )}
  end

  defp compile(path, name, block, line) do
    env = :elixir.env_for_eval(file: path, line: line)

    case Compiler.compile(name, block, env) do
      {:ok, tree} ->
        {:ok, tree}

      {:error, %Finding{} = finding} ->
        {:error, Error.new(:workflow_dsl, path, Finding.format(finding))}
    end
  end
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
