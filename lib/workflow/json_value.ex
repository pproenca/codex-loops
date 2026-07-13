defmodule Workflow.JSONValue do
  @moduledoc "Shared cardinality and emptiness semantics for JSON-shaped values."

  alias Workflow.JSONPointer

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
end
