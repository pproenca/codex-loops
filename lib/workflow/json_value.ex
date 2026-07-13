defmodule Workflow.JSONValue do
  @moduledoc "Shared validation, conversion, cardinality, and emptiness for JSON values."

  alias Workflow.JSONPointer

  @type literal_policy :: :finite_floats | :integers_only
  @type literal_error :: :duplicate_key | :invalid_key | :non_finite_float | :not_json

  @doc "Convert inert Elixir literal data into JSON data without evaluating quoted code."
  @spec from_literal(term(), literal_policy()) :: {:ok, term()} | {:error, literal_error()}
  def from_literal(value, policy \\ :finite_floats)

  def from_literal(nil, _policy), do: {:ok, nil}
  def from_literal(value, _policy) when is_boolean(value), do: {:ok, value}
  def from_literal(value, _policy) when is_integer(value), do: {:ok, value}
  def from_literal(value, _policy) when is_binary(value), do: {:ok, value}

  def from_literal(value, :finite_floats) when is_float(value) do
    if finite_float?(value), do: {:ok, value}, else: {:error, :non_finite_float}
  end

  def from_literal(value, _policy) when is_float(value), do: {:error, :not_json}
  def from_literal(value, _policy) when is_atom(value), do: {:ok, Atom.to_string(value)}

  def from_literal(values, policy) when is_list(values) do
    values
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, acc} ->
      case from_literal(value, policy) do
        {:ok, json} -> {:cont, {:ok, [json | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      {:error, _reason} = error -> error
    end
  end

  def from_literal({:%{}, _meta, pairs}, policy), do: object_from_literal(pairs, policy)

  def from_literal(value, policy) when is_map(value) and not is_struct(value) do
    object_from_literal(value, policy)
  end

  def from_literal(_value, _policy), do: {:error, :not_json}

  @spec finite_float?(term()) :: boolean()
  def finite_float?(value) when is_float(value), do: value - value == 0.0
  def finite_float?(_value), do: false

  @spec count(term()) :: non_neg_integer()
  def count(nil), do: 0
  def count(value) when is_list(value), do: length(value)
  def count(value) when is_map(value), do: map_size(value)
  def count(_scalar), do: 1

  @spec count_resolution(JSONPointer.resolution()) :: non_neg_integer()
  def count_resolution(:missing), do: 0
  def count_resolution({:present, value}), do: count(value)

  @spec non_empty?(term()) :: boolean()
  def non_empty?(nil), do: false
  def non_empty?(value) when is_binary(value), do: byte_size(value) > 0
  def non_empty?(value) when is_list(value), do: value != []
  def non_empty?(value) when is_map(value), do: map_size(value) > 0
  def non_empty?(_scalar), do: true

  @spec non_empty_resolution?(JSONPointer.resolution()) :: boolean()
  def non_empty_resolution?(:missing), do: false
  def non_empty_resolution?({:present, value}), do: non_empty?(value)

  @doc "Whether a value is the bounded integer/string-keyed JSON subset used in durable failure details."
  @spec durable_detail?(term()) :: boolean()
  def durable_detail?(value) when is_nil(value) or is_boolean(value), do: true
  def durable_detail?(value) when is_integer(value) or is_binary(value), do: true
  def durable_detail?(value) when is_list(value), do: Enum.all?(value, &durable_detail?/1)

  def durable_detail?(value) when is_map(value) do
    Enum.all?(value, fn {key, nested} -> is_binary(key) and durable_detail?(nested) end)
  end

  def durable_detail?(_value), do: false

  @doc "Keep JSON-encodable data or replace an opaque runtime value with diagnostics."
  @spec public(term()) :: term()
  def public(value) do
    case Jason.encode(value) do
      {:ok, _json} -> value
      {:error, _reason} -> inspect(value)
    end
  end

  @doc "Copy binaries throughout a JSON value before retaining decoded sub-binaries."
  @spec copy(term()) :: term()
  def copy(value) when is_binary(value), do: :binary.copy(value)
  def copy(value) when is_list(value), do: Enum.map(value, &copy/1)

  def copy(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {copy(key), copy(nested)} end)
  end

  def copy(value), do: value

  @doc "Normalize an atom or binary JSON object key without minting atoms."
  @spec object_key(term()) :: {:ok, String.t()} | {:error, :invalid_key}
  def object_key(key) when is_binary(key), do: {:ok, key}
  def object_key(key) when is_atom(key), do: {:ok, Atom.to_string(key)}
  def object_key(_key), do: {:error, :invalid_key}

  @doc "Render a public string value while preserving binaries and nil."
  @spec stringify(term()) :: String.t() | nil
  def stringify(nil), do: nil
  def stringify(value) when is_atom(value), do: Atom.to_string(value)
  def stringify(value) when is_binary(value), do: value
  def stringify(value), do: inspect(value)

  @doc "Compare normalized JSON values without conflating integers and floats."
  @spec equal?(term(), term()) :: boolean()
  def equal?(nil, nil), do: true
  def equal?(left, right) when is_boolean(left) and is_boolean(right), do: left == right
  def equal?(left, right) when is_integer(left) and is_integer(right), do: left == right

  def equal?(left, right) when is_float(left) and is_float(right),
    do: finite_float?(left) and finite_float?(right) and left == right

  def equal?(left, right) when is_binary(left) and is_binary(right), do: left == right

  def equal?(left, right) when is_list(left) and is_list(right) do
    length(left) == length(right) and left |> Enum.zip_with(right, &equal?/2) |> Enum.all?()
  end

  def equal?(left, right) when is_map(left) and is_map(right) do
    with {:ok, left} <- normalize_object(left),
         {:ok, right} <- normalize_object(right),
         true <- Enum.sort(Map.keys(left)) == Enum.sort(Map.keys(right)) do
      Enum.all?(left, fn {key, left_value} -> equal?(left_value, Map.fetch!(right, key)) end)
    else
      _other -> false
    end
  end

  def equal?(_left, _right), do: false

  @doc "Encode integer-only JSON deterministically by sorting object keys."
  @spec deterministic_encode(term()) :: String.t()
  def deterministic_encode(nil), do: "null"
  def deterministic_encode(true), do: "true"
  def deterministic_encode(false), do: "false"
  def deterministic_encode(value) when is_integer(value), do: Integer.to_string(value)
  def deterministic_encode(value) when is_binary(value), do: Jason.encode!(value)

  def deterministic_encode(value) when is_list(value) do
    "[" <> Enum.map_join(value, ",", &deterministic_encode/1) <> "]"
  end

  def deterministic_encode(value) when is_map(value) do
    encoded =
      value
      |> Enum.sort_by(fn {key, _nested} -> key end)
      |> Enum.map_join(",", fn {key, nested} ->
        deterministic_encode(key) <> ":" <> deterministic_encode(nested)
      end)

    "{" <> encoded <> "}"
  end

  defp object_from_literal(pairs, policy) do
    pairs
    |> Enum.reduce_while({:ok, %{}, MapSet.new()}, fn {key, value}, {:ok, object, keys} ->
      with {:ok, key} <- object_key(key),
           false <- MapSet.member?(keys, key),
           {:ok, value} <- from_literal(value, policy) do
        {:cont, {:ok, Map.put(object, key, value), MapSet.put(keys, key)}}
      else
        true -> {:halt, {:error, :duplicate_key}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, object, _keys} -> {:ok, object}
      {:error, _reason} = error -> error
    end
  end

  defp normalize_object(map) do
    map
    |> Enum.reduce_while({:ok, %{}, MapSet.new()}, fn {key, value}, {:ok, acc, seen} ->
      with {:ok, key} <- object_key(key),
           false <- MapSet.member?(seen, key) do
        {:cont, {:ok, Map.put(acc, key, value), MapSet.put(seen, key)}}
      else
        true -> {:halt, :error}
        {:error, :invalid_key} -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, normalized, _seen} -> {:ok, normalized}
      :error -> :error
    end
  end
end
