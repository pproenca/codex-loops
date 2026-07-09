defmodule Workflow.Scheduler.RunEventsProjection do
  @moduledoc """
  Scheduler-owned read projection for a run's journal events.

  This projection intentionally exposes only stable, client-safe fields for
  polling and progress inspection. Raw event payloads stay behind the scheduler
  boundary because they can contain internal terms that are not API contracts.
  """

  alias Workflow.Event
  alias Workflow.Scheduler.RunProjection
  alias Workflow.Status

  @enforce_keys [:run_id, :events, :run_projection]
  defstruct [:run_id, :events, :run_projection]

  @type event_projection :: %{
          required(:seq) => non_neg_integer(),
          required(:type) => String.t(),
          optional(:address) => Workflow.Node.address()
        }

  @type t :: %__MODULE__{
          run_id: String.t(),
          events: [event_projection()],
          run_projection: RunProjection.t()
        }

  @spec from_events(String.t(), [Event.t()]) :: t()
  def from_events(run_id, events) when is_binary(run_id) and is_list(events) do
    status = Status.fold(events, run_id)

    %__MODULE__{
      run_id: run_id,
      events: Enum.map(events, &event_to_map/1),
      run_projection: RunProjection.from_status(status, events: events)
    }
  end

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = projection) do
    projection.run_projection
    |> RunProjection.to_map()
    |> Map.put("journalEvents", projection.events)
    |> Map.put("events", projection.events)
  end

  defp event_to_map(%Event{seq: seq, type: type, payload: payload}) do
    put_present(%{seq: seq, type: Atom.to_string(type)}, :address, Map.get(payload, :address))
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)
end
