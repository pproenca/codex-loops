defmodule Workflow.Scheduler.RunEventsProjection do
  @moduledoc """
  Scheduler-owned read projection for a run's journal events.

  This projection intentionally exposes only stable, client-safe fields for
  polling and progress inspection. Raw event payloads stay behind the scheduler
  boundary because they can contain internal terms that are not API contracts.
  """

  alias Workflow.Event

  @enforce_keys [:run_id, :events]
  defstruct [:run_id, :events]

  @type event_projection :: %{
          required(:seq) => non_neg_integer(),
          required(:type) => String.t(),
          optional(:address) => Workflow.Node.address()
        }

  @type t :: %__MODULE__{
          run_id: String.t(),
          events: [event_projection()]
        }

  @spec from_events(String.t(), [Event.t()]) :: t()
  def from_events(run_id, events) when is_binary(run_id) and is_list(events) do
    %__MODULE__{
      run_id: run_id,
      events: Enum.map(events, &event_to_map/1)
    }
  end

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = projection) do
    %{
      run_id: projection.run_id,
      events: projection.events
    }
  end

  defp event_to_map(%Event{seq: seq, type: type, payload: payload}) do
    %{seq: seq, type: Atom.to_string(type)}
    |> put_present(:address, Map.get(payload, :address))
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)
end
