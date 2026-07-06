defmodule Workflow do
  @moduledoc """
  The workflow DSL entry point.

      defmodule Demo do
        use Workflow

        workflow "demo" do
          phase "p"
          log "hi"
          agent "say hello"
          return :ok
        end
      end

  `use Workflow` only imports the `workflow/2` macro. That macro is a **thin
  shell**: it hands the quoted body to `Workflow.Compiler.parse/2`, escapes the
  resulting inert `%Workflow.Tree{}` into a compile-time constant, and exposes it
  through a generated `__workflow__/1` reflection function. No workflow logic — no
  closures — is generated; the tree is pure data.
  """

  defmacro __using__(_opts) do
    quote do
      import Workflow, only: [workflow: 2]
    end
  end

  @doc """
  Compile a workflow into `__workflow__(:tree)` / `__workflow__(:name)`.

  All validation happens here, at expansion time, so mistakes fail `mix compile`
  rather than the first request.
  """
  defmacro workflow(name, do: block) when is_binary(name) do
    case Workflow.Compiler.parse(block, __CALLER__) do
      {:ok, tree} ->
        escaped = Macro.escape(%{tree | name: name})

        quote do
          def __workflow__(:tree), do: unquote(escaped)
          def __workflow__(:name), do: unquote(name)
        end

      {:error, finding} ->
        raise Workflow.CompileError, Workflow.Compiler.Finding.format(finding)
    end
  end

  defmacro workflow(name, _block) do
    raise Workflow.CompileError,
          "workflow name must be a string literal, got: #{Macro.to_string(name)}"
  end
end
