defmodule Workflow.BoundValue do
  @moduledoc """
  Resolves a single bound value **purely by folding the journal**.

  A `{:node, address}` binding points at one producer node's committed result.
  The fold replays the latest committed result for that address and returns it as a
  tagged tuple, so later slices can widen prompt rendering to journaled values
  without introducing process state.
  """

  alias Workflow.Event
  alias Workflow.Journal

  @type result :: {:ok, term()} | {:error, {:unbound, Workflow.Node.binding_ref()}}

  @spec of(String.t(), Workflow.Node.binding_ref()) :: result()
  def of(run_id, ref), do: run_id |> Journal.fold() |> fold(ref)

  @spec fold([Event.t()], Workflow.Node.binding_ref()) :: result()
  def fold(events, {:node, address} = ref) do
    case Enum.reduce(events, nil, &apply_event(&1, &2, address)) do
      nil -> {:error, {:unbound, ref}}
      result -> {:ok, result}
    end
  end

  def fold(events, {:refine, address} = ref) do
    case Enum.reduce(events, nil, &apply_refine_event(&1, &2, address)) do
      nil -> {:error, {:unbound, ref}}
      result -> {:ok, result}
    end
  end

  def fold(_events, {:map, _address} = ref), do: {:error, {:unbound, ref}}
  def fold(_events, {:fanout, _address, _scope} = ref), do: {:error, {:unbound, ref}}

  defp apply_event(%Event{type: :agent_committed, payload: %{address: address, result: result}}, _acc, address),
    do: result

  defp apply_event(%Event{}, acc, _address), do: acc

  defp apply_refine_event(
         %Event{type: :refine_completed, payload: %{address: address, artifact: artifact}},
         _acc,
         address
       ), do: artifact

  defp apply_refine_event(%Event{}, acc, _address), do: acc
end
