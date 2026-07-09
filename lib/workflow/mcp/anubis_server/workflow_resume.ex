defmodule Workflow.MCP.AnubisServer.WorkflowResume do
  @moduledoc "Resume an existing scheduler run through POST /api/runs/:id/resume."

  use Anubis.Server.Component, type: :tool, name: "workflow_resume"

  alias Workflow.MCP.AnubisServer.ToolHelpers
  alias Workflow.MCP.SchedulerClient

  @allowed_keys [:script_path, :script, :provider]

  schema do
    field(:run_id, {:required, {:string, {:min, 1}}}, description: "Existing run id to resume.")

    field(:script_path, :string, description: "Optional workflow .exs path to use instead of the journaled script path.")

    field(:script, :string, description: "Optional scheduler-supported alias for script_path.")

    field(:provider, {:enum, ["mock", "codex"]},
      description: "Optional scheduler provider. Defaults to mock; codex spends a real Codex turn."
    )
  end

  @impl true
  def execute(%{run_id: run_id} = arguments, frame) when is_binary(run_id) do
    attrs = arguments |> Map.take(@allowed_keys) |> stringify_keys()
    ToolHelpers.scheduler_tool(frame, fn -> SchedulerClient.resume_run(run_id, attrs) end)
  end

  defp stringify_keys(map) do
    Map.new(map, fn {key, value} -> {Atom.to_string(key), value} end)
  end
end
