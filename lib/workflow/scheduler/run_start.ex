defmodule Workflow.Scheduler.RunStart do
  @moduledoc "Accepted run-start response returned by the scheduler API boundary."

  @enforce_keys [:run_id, :state, :ui_path, :ui_url]
  defstruct [:run_id, :state, :ui_path, :ui_url]

  @type t :: %__MODULE__{
          run_id: String.t(),
          state: :accepted,
          ui_path: String.t(),
          ui_url: String.t()
        }

  @spec accepted(String.t()) :: t()
  def accepted(run_id) do
    ui_path = "/runs/#{run_id}"

    %__MODULE__{
      run_id: run_id,
      state: :accepted,
      ui_path: ui_path,
      ui_url: ui_path
    }
  end

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = start) do
    %{
      run_id: start.run_id,
      state: start.state,
      ui_path: start.ui_path,
      ui_url: start.ui_url
    }
  end
end
