defmodule Workflow.Scheduler.LifecycleAction do
  @moduledoc "The single lifecycle affordance exposed for a run."

  @enforce_keys [:action, :label, :enabled, :reason, :method, :href]
  defstruct @enforce_keys

  @type action :: :pause_unavailable | :resume_unavailable | :run_unavailable | :resume | :none
  @type t :: %__MODULE__{
          action: action(),
          label: String.t(),
          enabled: boolean(),
          reason: String.t(),
          method: String.t() | nil,
          href: String.t() | nil
        }
end
