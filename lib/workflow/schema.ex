defmodule Workflow.Schema do
  @moduledoc """
  Validates a decoded provider result against a raw JSON-schema map.

  This is the **fail-closed gate**: a schema-backed agent's output only proceeds
  downstream if `validate/2` returns `{:ok, term}`. It is a pure function over
  already-decoded terms (maps, lists, scalars) — the provider adapter owns any
  JSON decoding — so the runner can validate, journal the reason on failure, and
  decide retry-vs-fail deterministically.

  It covers the JSON-schema subset structured outputs actually use — `object`
  (with `properties`/`required`), `string`, `integer`, `number`, `boolean`, and
  `array` (with `items`). A schema with no recognized `type` is permissive, so
  later slices can extend the vocabulary without this rejecting forward-compatible
  schemas.
  """

  @spec validate(map(), term()) :: {:ok, term()} | {:error, term()}
  def validate(schema, value) when is_map(schema) do
    case check(schema, value) do
      :ok -> {:ok, value}
      {:error, _reason} = error -> error
    end
  end

  defp check(%{"type" => "object"} = schema, value) when is_map(value) do
    required = Map.get(schema, "required", [])
    properties = Map.get(schema, "properties", %{})

    with :ok <- check_required(required, value) do
      check_properties(properties, value)
    end
  end

  defp check(%{"type" => "object"}, value), do: {:error, {:expected_object, value}}

  defp check(%{"type" => "string"}, value) when is_binary(value), do: :ok
  defp check(%{"type" => "string"}, value), do: {:error, {:expected_string, value}}

  defp check(%{"type" => "integer"}, value) when is_integer(value), do: :ok
  defp check(%{"type" => "integer"}, value), do: {:error, {:expected_integer, value}}

  # A JSON number matches integers too, but a boolean is never a number.
  defp check(%{"type" => "number"}, value) when is_number(value), do: :ok
  defp check(%{"type" => "number"}, value), do: {:error, {:expected_number, value}}

  defp check(%{"type" => "boolean"}, value) when is_boolean(value), do: :ok
  defp check(%{"type" => "boolean"}, value), do: {:error, {:expected_boolean, value}}

  defp check(%{"type" => "array"} = schema, value) when is_list(value) do
    case Map.fetch(schema, "items") do
      {:ok, item_schema} -> check_each(item_schema, value)
      :error -> :ok
    end
  end

  defp check(%{"type" => "array"}, value), do: {:error, {:expected_array, value}}

  # No recognized type: accept, so unknown/forward-compatible schemas do not reject.
  defp check(_schema, _value), do: :ok

  defp check_required(required, map) do
    case Enum.find(required, fn key -> not Map.has_key?(map, key) end) do
      nil -> :ok
      missing -> {:error, {:missing_required, missing}}
    end
  end

  defp check_properties(properties, map) do
    Enum.reduce_while(properties, :ok, fn {key, sub_schema}, :ok ->
      case Map.fetch(map, key) do
        {:ok, value} ->
          case check(sub_schema, value) do
            :ok -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, {:property, key, reason}}}
          end

        # Absent optional properties are the concern of `required`, not typing.
        :error ->
          {:cont, :ok}
      end
    end)
  end

  defp check_each(item_schema, list) do
    Enum.reduce_while(list, :ok, fn element, :ok ->
      case check(item_schema, element) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:item, reason}}}
      end
    end)
  end
end
