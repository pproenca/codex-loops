defmodule Workflow.Install.Error do
  @moduledoc false

  @enforce_keys [:status, :code, :message]
  defstruct [:status, :code, :message, :details, :step, changed: false]

  @type t :: %__MODULE__{
          status: 1..6,
          code: String.t(),
          message: String.t(),
          details: map() | nil,
          step: String.t() | nil,
          changed: boolean()
        }

  @spec new(1..6, String.t(), String.t(), keyword()) :: t()
  def new(status, code, message, opts \\ []) do
    %__MODULE__{
      status: status,
      code: code,
      message: message,
      details: Keyword.get(opts, :details),
      step: Keyword.get(opts, :step),
      changed: Keyword.get(opts, :changed, false)
    }
  end

  @spec changed(t(), boolean()) :: t()
  def changed(%__MODULE__{} = error, changed), do: %{error | changed: error.changed or changed}

  @spec step(t(), String.t()) :: t()
  def step(%__MODULE__{step: nil} = error, step), do: %{error | step: step}
  def step(%__MODULE__{} = error, _step), do: error

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = error) do
    %{"code" => error.code, "message" => error.message}
    |> put_optional("details", error.details)
    |> put_optional("step", error.step)
  end

  defp put_optional(map, _key, nil), do: map
  defp put_optional(map, key, value), do: Map.put(map, key, value)
end
