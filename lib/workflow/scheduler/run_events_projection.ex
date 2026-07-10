defmodule Workflow.Scheduler.RunEventsProjection do
  @moduledoc """
  Scheduler-owned read projection for a run's journal events.

  This projection intentionally exposes only stable, client-safe fields for
  polling and progress inspection. Raw event payloads stay behind the scheduler
  boundary because they can contain internal terms that are not API contracts.
  """

<<<<<<< HEAD
  alias Workflow.Event
  alias Workflow.Scheduler.RunProjection
  alias Workflow.Status

  @enforce_keys [:run_id, :events, :run_projection]
  defstruct [:run_id, :events, :run_projection]
=======
  alias Workflow.{Event, Status}
  alias Workflow.Scheduler.RunProjection

  @enforce_keys [:run_id, :events, :inspector]
  defstruct [:run_id, :events, :inspector]
>>>>>>> codex/run-inspector-followups

  @type event_projection :: %{
          required(:seq) => non_neg_integer(),
          required(:type) => String.t(),
          optional(:address) => Workflow.Node.address()
        }

  @type t :: %__MODULE__{
          run_id: String.t(),
          events: [event_projection()],
<<<<<<< HEAD
          run_projection: RunProjection.t()
=======
          inspector: map()
>>>>>>> codex/run-inspector-followups
        }

  @spec from_events(String.t(), [Event.t()]) :: t()
  def from_events(run_id, events) when is_binary(run_id) and is_list(events) do
    status = Status.fold(events, run_id)

    %__MODULE__{
      run_id: run_id,
      events: Enum.map(events, &event_to_map/1),
<<<<<<< HEAD
      run_projection: RunProjection.from_status(status, events: events)
=======
      inspector: RunProjection.inspector_from_status(status)
>>>>>>> codex/run-inspector-followups
    }
  end

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = projection) do
<<<<<<< HEAD
    projection.run_projection
    |> RunProjection.to_map()
    |> Map.put("journalEvents", projection.events)
    |> Map.put("events", projection.events)
=======
    %{
      run_id: projection.run_id,
      events: projection.events,
      inspector: projection.inspector
    }
>>>>>>> codex/run-inspector-followups
  end

  defp event_to_map(%Event{seq: seq, type: type, payload: payload}) do
    put_present(%{seq: seq, type: Atom.to_string(type)}, :address, Map.get(payload, :address))
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)
end
