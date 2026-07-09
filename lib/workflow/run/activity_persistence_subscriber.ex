defmodule Workflow.Run.ActivityPersistenceSubscriber do
  @moduledoc """
  Persists provider activity progress messages out of band.

  Provider activity starts life as a progress message on `Workflow.Run.Stream`.
  This subscriber makes that telemetry durable by appending `agent_activity`
  journal events idempotently. Writer-owned settlements remain authoritative:
  losing or restarting this process can affect when persisted activity appears in
  snapshots, but it cannot decide retries, usage ledgering, resume, or terminal
  state.
  """
  use GenServer

  alias Workflow.Event
  alias Workflow.Journal
  alias Workflow.Run.Stream, as: RunStream

  @resubscribe_ms 50

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    {:ok, subscribe(%{})}
  end

  @impl true
  def handle_info({:run_stream_event, run_id, %Event{type: :agent_activity} = event}, state) do
    {:ok, persisted} = Journal.append_next(run_id, event)
    Phoenix.PubSub.broadcast(Workflow.PubSub, "run:" <> run_id, {:journal_committed, run_id, persisted})
    {:noreply, state}
  end

  def handle_info({:run_stream_event, _run_id, %Event{}}, state), do: {:noreply, state}

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{pubsub_ref: ref} = state) do
    schedule_resubscribe()
    {:noreply, %{state | pubsub_pid: nil, pubsub_ref: nil}}
  end

  def handle_info(:resubscribe, state), do: {:noreply, subscribe(state)}

  defp subscribe(%{pubsub_pid: pid, pubsub_ref: ref} = state) when is_pid(pid) and is_reference(ref) do
    if Process.whereis(Workflow.PubSub) == pid do
      state
    else
      schedule_resubscribe()
      Map.merge(state, %{pubsub_pid: nil, pubsub_ref: nil})
    end
  end

  defp subscribe(state) do
    case Process.whereis(Workflow.PubSub) do
      pid when is_pid(pid) ->
        case RunStream.subscribe_all() do
          :ok ->
            Map.merge(state, %{pubsub_pid: pid, pubsub_ref: Process.monitor(pid)})

          {:error, _reason} ->
            schedule_resubscribe()
            Map.merge(state, %{pubsub_pid: nil, pubsub_ref: nil})
        end

      _missing ->
        schedule_resubscribe()
        Map.merge(state, %{pubsub_pid: nil, pubsub_ref: nil})
    end
  end

  defp schedule_resubscribe, do: Process.send_after(self(), :resubscribe, @resubscribe_ms)
end
