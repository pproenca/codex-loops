defmodule Workflow.Scheduler.Health do
  @moduledoc "Health snapshot for the scheduler API boundary."

  @enforce_keys [:status, :version, :checks]
  defstruct [:status, :version, :checks]

  @type availability :: :available | :unavailable

  @type t :: %__MODULE__{
          status: :ok,
          version: String.t(),
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
      version: health.version,
      checks: health.checks
    }
  end
end
