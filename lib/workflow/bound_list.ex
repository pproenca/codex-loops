defmodule Workflow.BoundList do
  @moduledoc """
  Resolves a bound list **purely by folding the journal**.

  A `{:map, address}` binding replays each committed lane result under that
  address, ordered by lane index, so future slices can splice runtime map outputs
  into prompts without changing the render algorithm.
  """

  alias Workflow.{Journal, Event}

  @type result :: {:ok, [term()]} | {:error, {:unbound, Workflow.Node.binding_ref()}}

  @spec of(String.t(), Workflow.Node.binding_ref()) :: result()
  def of(run_id, ref), do: run_id |> Journal.fold() |> fold(ref)

  @spec fold([Event.t()], Workflow.Node.binding_ref()) :: result()
  def fold(events, {:map, address} = ref) do
    lanes =
      Enum.reduce(events, %{}, fn
        %Event{type: :agent_committed, payload: %{address: lane_address, result: result}}, acc ->
          case lane_index(address, lane_address) do
            {:ok, lane} -> Map.put(acc, lane, result)
            :error -> acc
          end

        %Event{}, acc ->
          acc
      end)

    case lanes do
      map when map_size(map) == 0 ->
        {:error, {:unbound, ref}}

      map ->
        {:ok, map |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(&elem(&1, 1))}
    end
  end

  def fold(_events, {:node, _address} = ref), do: {:error, {:unbound, ref}}

  defp lane_index(address, lane_address) do
    if List.starts_with?(lane_address, address) do
      case Enum.drop(lane_address, length(address)) do
        [lane] when is_integer(lane) and lane >= 0 -> {:ok, lane}
        _other -> :error
      end
    else
      :error
    end
  end
end
