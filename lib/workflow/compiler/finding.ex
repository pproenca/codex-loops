defmodule Workflow.Compiler.Finding do
  @moduledoc """
  A structured compile-time diagnostic. Slice #1 carries a generic message and the
  offending form; precise source locations (rustc-style, pointing at the caller's
  line) are a later slice — the shape is stable so that extension is additive.
  """
  @enforce_keys [:message]
  defstruct [:message, :form]

  @type t :: %__MODULE__{message: String.t(), form: Macro.t() | nil}

  @spec new(String.t(), Macro.t()) :: t()
  def new(message, form), do: %__MODULE__{message: message, form: form}
end
