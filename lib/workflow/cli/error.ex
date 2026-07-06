defmodule Workflow.CLI.Error do
  @moduledoc """
  A single CLI failure, carrying the contract's error `code`, a human `message`,
  and an optional `hint`. The `code` is the sole source of truth for both the
  process exit code and the JSON error object's `code` string, so the exit-code
  contract and the JSON discipline can never drift apart.

  | code               | json code          | exit |
  |--------------------|--------------------|------|
  | `:usage`           | `usage`            | 2    |
  | `:provider_config` | `provider-config`  | 4    |
  | `:validation`      | `validation`       | 6    |
  | `:malformed_output`| `malformed-output` | 8    |
  | `:killed`          | `killed`           | 130  |
  | `:runtime`         | `runtime`          | 1    |
  """

  @enforce_keys [:code, :message]
  defstruct [:code, :message, :hint]

  @type code ::
          :usage | :provider_config | :validation | :malformed_output | :killed | :runtime

  @type t :: %__MODULE__{code: code(), message: String.t(), hint: String.t() | nil}

  @exit_codes %{
    usage: 2,
    provider_config: 4,
    validation: 6,
    malformed_output: 8,
    killed: 130,
    runtime: 1
  }

  @json_codes %{
    usage: "usage",
    provider_config: "provider-config",
    validation: "validation",
    malformed_output: "malformed-output",
    killed: "killed",
    runtime: "runtime"
  }

  @spec new(code(), String.t(), String.t() | nil) :: t()
  def new(code, message, hint \\ nil) when is_map_key(@exit_codes, code),
    do: %__MODULE__{code: code, message: message, hint: hint}

  @doc "The process exit code for this error's `code`."
  @spec exit_code(t()) :: pos_integer()
  def exit_code(%__MODULE__{code: code}), do: Map.fetch!(@exit_codes, code)

  @doc """
  The single-line JSON error object printed as the last stderr line under `--json`.
  Shaped `{"code","exitCode","message","hint"?}`.
  """
  @spec to_json(t()) :: String.t()
  def to_json(%__MODULE__{} = e) do
    %{"code" => Map.fetch!(@json_codes, e.code), "exitCode" => exit_code(e), "message" => e.message}
    |> maybe_hint(e.hint)
    |> Jason.encode!()
  end

  defp maybe_hint(map, nil), do: map
  defp maybe_hint(map, hint), do: Map.put(map, "hint", hint)
end
