defmodule Workflow.BoundList do
  @moduledoc """
  Resolves a bound list **purely by folding the journal**.

  A `{:map, address}` or fanout binding replays committed lane results under that
  address, ordered by lane index, so list-valued producers can be spliced into
  prompts without changing the render algorithm.
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

  def fold(events, {:fanout, address, :global} = ref), do: fold_fanout(events, address, nil, ref)

  def fold(_events, {:fanout, _address, {:loop_local, _loop_address}} = ref),
    do: {:error, {:unbound, ref}}

  def fold(_events, {:node, _address} = ref), do: {:error, {:unbound, ref}}
  def fold(_events, {:refine, _address} = ref), do: {:error, {:unbound, ref}}

  @spec fold([Event.t()], Workflow.Node.binding_ref(), non_neg_integer()) :: result()
  def fold(events, {:fanout, address, {:loop_local, _loop_address}} = ref, iteration)
      when is_integer(iteration) and iteration >= 0,
      do: fold_fanout(events, address, iteration, ref)

  def fold(events, ref, _iteration), do: fold(events, ref)

  defp fold_fanout(events, address, iteration, ref) do
    with {:ok, width} <- fanout_width(events, address, iteration, ref) do
      event_iteration = iteration || 0

      0..(width - 1)//1
      |> Enum.reduce_while({:ok, []}, fn lane, {:ok, acc} ->
        case fanout_lane_result(events, address, lane, event_iteration) do
          {:ok, result} -> {:cont, {:ok, [result | acc]}}
          :error -> {:halt, {:error, {:unbound, ref}}}
        end
      end)
      |> case do
        {:ok, results} -> {:ok, Enum.reverse(results)}
        {:error, _} = error -> error
      end
    end
  end

  defp fanout_width(events, address, iteration, ref) do
    case Enum.find(events, fn
           %Event{type: :fanout_started, payload: payload} ->
             payload.address == address and Map.get(payload, :iteration) == iteration

           %Event{} ->
             false
         end) do
      nil -> {:error, {:unbound, ref}}
      %Event{payload: %{width: width}} -> {:ok, width}
    end
  end

  defp fanout_lane_result(events, address, lane, iteration) do
    lane_prefix = address ++ [lane]

    events
    |> Enum.filter(fn
      %Event{type: :agent_committed, payload: payload} ->
        payload.iteration == iteration and List.starts_with?(payload.address, lane_prefix)

      %Event{} ->
        false
    end)
    |> Enum.sort_by(& &1.payload.address)
    |> List.last()
    |> case do
      %Event{payload: %{result: result}} -> {:ok, result}
      nil -> :error
    end
  end

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
