defmodule Workflow.MCP.AnubisServer.WorkflowInspect do
  @moduledoc "Read the public §7.5 inspect/status projection with ordered rawRefs through GET /api/runs/:id/events."

  use Anubis.Server.Component, type: :tool, name: "workflow_inspect"

  alias Workflow.MCP.AnubisServer.ToolHelpers
  alias Workflow.MCP.SchedulerClient

  schema do
    field(:run_id, {:required, {:string, {:min, 1}}},
      description: "Run id returned by workflow_start or workflow_resume."
    )
  end

  @impl true
  def execute(%{run_id: run_id}, frame) when is_binary(run_id) do
    ToolHelpers.scheduler_projection_tool(frame, fn -> SchedulerClient.get_run_events(run_id) end)
  end
end
