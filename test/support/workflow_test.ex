defmodule Workflow.Test do
  @moduledoc false

  alias Workflow.Compiler
  alias Workflow.Tree

  @spec tree!(String.t(), Macro.t(), Macro.Env.t()) :: Tree.t()
  def tree!(name, body, env) when is_binary(name) do
    {:ok, %Tree{} = tree} = Compiler.compile(name, body, env)
    tree
  end
end
