defmodule Workflow.Run.Input do
  @moduledoc """
  Normalizes and validates immutable workflow invocation arguments.

  Arguments are ordinary JSON data and are bounded before they enter the
  journal. They are deliberately not a secret channel: the normalized value is
  durable and visible through scheduler inspection.
  """

  alias Workflow.JSONValue
  alias Workflow.PlanIdentity
  alias Workflow.Schema

  @max_bytes 64 * 1024

  @type error :: :not_json | :non_finite_float | {:too_large, non_neg_integer(), pos_integer()} | {:schema, term()}

  @spec max_bytes() :: pos_integer()
  def max_bytes, do: @max_bytes

  @spec normalize(term()) :: {:ok, term()} | {:error, error()}
  def normalize(value) do
    with {:ok, normalized} <- normalize_json(value),
         {:ok, encoded} <- Jason.encode(normalized),
         :ok <- within_limit(byte_size(encoded)) do
      {:ok, JSONValue.copy(normalized)}
    else
      {:error, %Jason.EncodeError{}} -> {:error, :not_json}
      {:error, _reason} = error -> error
    end
  end

  @spec validate(Schema.t() | nil, term()) :: :ok | {:error, error()}
  def validate(nil, _args), do: :ok

  def validate(schema, args) do
    case Schema.validate(schema, args) do
      {:ok, _args} -> :ok
      {:error, reason} -> {:error, {:schema, reason}}
    end
  end

  @spec digest(term()) :: String.t()
  def digest(args), do: PlanIdentity.input_digest(args)

  defp normalize_json(nil), do: {:ok, nil}
  defp normalize_json(value) when is_boolean(value) or is_integer(value) or is_binary(value), do: {:ok, value}

  defp normalize_json(value) when is_float(value) do
    if JSONValue.finite_float?(value), do: {:ok, value}, else: {:error, :non_finite_float}
  end

  defp normalize_json(values) when is_list(values) do
    values
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, acc} ->
      case normalize_json(value) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      {:error, _reason} = error -> error
    end
  end

  defp normalize_json(value) when is_map(value) and not is_struct(value) do
    Enum.reduce_while(value, {:ok, %{}}, fn
      {key, nested}, {:ok, acc} when is_binary(key) ->
        case normalize_json(nested) do
          {:ok, normalized} -> {:cont, {:ok, Map.put(acc, key, normalized)}}
          {:error, _reason} = error -> {:halt, error}
        end

      {_key, _nested}, _acc ->
        {:halt, {:error, :not_json}}
    end)
  end

  defp normalize_json(_value), do: {:error, :not_json}

  defp within_limit(bytes) when bytes <= @max_bytes, do: :ok
  defp within_limit(bytes), do: {:error, {:too_large, bytes, @max_bytes}}
end
