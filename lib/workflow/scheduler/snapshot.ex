defmodule Workflow.Scheduler.Snapshot do
  @moduledoc "A status fold and its scheduler-owned projection from one journal read."

  @enforce_keys [:status, :run_projection]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          status: Workflow.Status.t(),
          run_projection: Workflow.Scheduler.RunProjection.t()
        }
end
