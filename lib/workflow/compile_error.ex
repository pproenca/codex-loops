defmodule Workflow.CompileError do
  @moduledoc """
  Raised at `mix compile` when a workflow body contains a form outside the closed
  combinator vocabulary (an unknown call, a closure, or any non-combinator
  expression). Determinism is enforced by this rejection plus the *absence* of any
  node for randomness or wall-clock — never by a runtime linter.
  """
  defexception [:message]
end
