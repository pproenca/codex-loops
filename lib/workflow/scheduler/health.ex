defmodule Workflow.Scheduler.Health do
  @moduledoc "Health snapshot for the scheduler API boundary."

  @enforce_keys [:status, :checks]
  defstruct [:status, :checks]

  @type availability :: :available | :unavailable

  @type t :: %__MODULE__{
          status: :ok,
          checks: %{
            otp_app: availability(),
            journal: availability(),
            pubsub: availability(),
            endpoint: availability()
          }
        }

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = health) do
    %{
      status: health.status,
      checks: health.checks
    }
  end
end
