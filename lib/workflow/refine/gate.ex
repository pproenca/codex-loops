defmodule Workflow.Refine.Gate do
  @moduledoc """
  Closed predicate evaluation for refine cold-read, repair, and halt gates.

  Gates deliberately operate on the public string-keyed refine result JSON shape.
  They distinguish missing paths from present JSON nulls, which the template
  formatter does not need to do.
  """

  @type compare_op :: :> | :< | :>= | :<= | :==
  @type predicate ::
          {:path_exists, String.t()}
          | {:path_non_empty, String.t()}
          | {:path_count, String.t(), compare_op(), integer()}
          | {:path_equals, String.t(), term()}

  @spec evaluate(predicate(), map()) :: boolean()
  def evaluate({:path_exists, pointer}, json), do: match?({:present, _}, resolve(json, pointer))

  def evaluate({:path_non_empty, pointer}, json) do
    case resolve(json, pointer) do
      :missing -> false
      {:present, value} -> non_empty?(value)
    end
  end

  def evaluate({:path_count, pointer, op, right}, json) do
    json
    |> resolve(pointer)
    |> count()
    |> compare(op, right)
  end

  def evaluate({:path_equals, pointer, literal}, json) do
    case resolve(json, pointer) do
      :missing -> false
      {:present, value} -> value == literal
    end
  end

  @spec valid_pointer?(term()) :: boolean()
  def valid_pointer?(pointer) when is_binary(pointer) do
    (pointer == "" or String.starts_with?(pointer, "/")) and valid_escapes?(pointer)
  end

  def valid_pointer?(_pointer), do: false

  @spec resolve(map(), String.t()) :: {:present, term()} | :missing
  def resolve(value, ""), do: {:present, value}

  def resolve(value, "/" <> rest) do
    rest
    |> String.split("/")
    |> Enum.map(&unescape_token/1)
    |> Enum.reduce_while({:present, value}, fn token, {:present, current} ->
      case step(current, token) do
        {:present, _value} = present -> {:cont, present}
        :missing -> {:halt, :missing}
      end
    end)
  end

  def resolve(_value, _pointer), do: :missing

  defp step(current, token) when is_map(current) do
    case Map.fetch(current, token) do
      {:ok, value} -> {:present, value}
      :error -> :missing
    end
  end

  defp step(current, token) when is_list(current) do
    with true <- canonical_index?(token),
         {index, ""} <- Integer.parse(token),
         true <- index < length(current) do
      {:present, Enum.at(current, index)}
    else
      _other -> :missing
    end
  end

  defp step(_current, _token), do: :missing

  defp non_empty?(nil), do: false
  defp non_empty?(value) when is_binary(value), do: byte_size(value) > 0
  defp non_empty?(value) when is_list(value), do: value != []
  defp non_empty?(value) when is_map(value), do: map_size(value) > 0
  defp non_empty?(_scalar), do: true

  defp count(:missing), do: 0
  defp count({:present, nil}), do: 0
  defp count({:present, value}) when is_list(value), do: length(value)
  defp count({:present, value}) when is_map(value), do: map_size(value)
  defp count({:present, _scalar}), do: 1

  defp compare(left, :>, right), do: left > right
  defp compare(left, :<, right), do: left < right
  defp compare(left, :>=, right), do: left >= right
  defp compare(left, :<=, right), do: left <= right
  defp compare(left, :==, right), do: left == right

  defp canonical_index?("0"), do: true

  defp canonical_index?(token) do
    String.match?(token, ~r/^[1-9][0-9]*$/)
  end

  defp valid_escapes?(pointer) do
    pointer
    |> String.graphemes()
    |> valid_escape_tokens?()
  end

  defp valid_escape_tokens?([]), do: true

  defp valid_escape_tokens?(["~", next | rest]) when next in ["0", "1"], do: valid_escape_tokens?(rest)

  defp valid_escape_tokens?(["~" | _rest]), do: false
  defp valid_escape_tokens?([_char | rest]), do: valid_escape_tokens?(rest)

  defp unescape_token(token) do
    token
    |> String.replace("~1", "/")
    |> String.replace("~0", "~")
  end
end
