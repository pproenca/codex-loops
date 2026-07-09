defmodule Workflow.MCP.AnubisServer.WorkflowStatus do
  @moduledoc "Read the public §7.5 status projection through GET /api/runs/:id."

  use Anubis.Server.Component, type: :tool, name: "workflow_status"

  alias Workflow.MCP.AnubisServer.ToolHelpers
  alias Workflow.MCP.SchedulerClient

  schema do
    field(:run_id, {:required, {:string, {:min, 1}}}, description: "Run id returned by workflow_start.")
  end

  @impl true
  def execute(%{run_id: run_id}, frame) when is_binary(run_id) do
    ToolHelpers.scheduler_projection_tool(frame, fn -> SchedulerClient.get_run(run_id) end)
  end
end
