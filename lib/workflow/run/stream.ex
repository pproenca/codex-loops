defmodule Workflow.Run.Stream do
  @moduledoc """
  Realtime run progress-message bus.

  Provider activity is progress telemetry, not the durable exactly-once ledger.
  The runner emits it here first so connected read surfaces can render immediately.
  Durable persistence is just another subscriber:
  `Workflow.Run.ActivityPersistenceSubscriber` listens to the global stream topic
  and records activity out of band.
  """

  alias Workflow.Event
  alias Workflow.PubSub

  @global_topic "runs:stream"

  @spec subscribe(String.t()) :: :ok | {:error, term()}
  def subscribe(run_id) when is_binary(run_id) do
    Phoenix.PubSub.subscribe(PubSub, run_topic(run_id))
  end

  @spec subscribe_all() :: :ok | {:error, term()}
  def subscribe_all do
    Phoenix.PubSub.subscribe(PubSub, @global_topic)
  end

  @spec emit(String.t(), Event.t()) :: :ok
  def emit(run_id, %Event{} = event) when is_binary(run_id) do
    message = {:run_stream_event, run_id, %{event | run_id: run_id}}
    Phoenix.PubSub.broadcast(PubSub, @global_topic, message)
    Phoenix.PubSub.broadcast(PubSub, run_topic(run_id), message)
    :ok
  end

  defp run_topic(run_id), do: "run:" <> run_id
end
