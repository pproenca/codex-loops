defmodule Workflow.Refine.Gate do
  @moduledoc """
  Closed predicate evaluation for refine cold-read, repair, and halt gates.

  Gates deliberately operate on the public string-keyed refine result JSON shape.
  They distinguish missing paths from present JSON nulls, which the template
  formatter does not need to do.
  """

  alias Workflow.JSONPointer

  @type compare_op :: :> | :< | :>= | :<= | :==
  @type predicate ::
          {:path_exists, String.t()}
          | {:path_non_empty, String.t()}
          | {:path_count, String.t(), compare_op(), integer()}
          | {:path_equals, String.t(), term()}

  @spec evaluate(predicate(), map()) :: boolean()
  def evaluate({:path_exists, pointer}, json), do: match?({:present, _}, JSONPointer.resolve(json, pointer))

  def evaluate({:path_non_empty, pointer}, json) do
    case JSONPointer.resolve(json, pointer) do
      :missing -> false
      {:present, value} -> non_empty?(value)
    end
  end

  def evaluate({:path_count, pointer, op, right}, json) do
    json
    |> JSONPointer.resolve(pointer)
    |> count()
    |> compare(op, right)
  end

  def evaluate({:path_equals, pointer, literal}, json) do
    case JSONPointer.resolve(json, pointer) do
      :missing -> false
      {:present, value} -> value == literal
    end
  end

  @spec valid_pointer?(term()) :: boolean()
  def valid_pointer?(pointer), do: JSONPointer.valid?(pointer)

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
end
