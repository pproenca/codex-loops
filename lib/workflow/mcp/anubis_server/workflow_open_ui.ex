defmodule Workflow.MCP.AnubisServer.WorkflowOpenUI do
  @moduledoc "Return the Phoenix LiveView URL for a scheduler run."

  use Anubis.Server.Component, type: :tool, name: "workflow_open_ui"

  alias Workflow.MCP.AnubisServer.ToolHelpers

  schema do
    field(:run_id, {:required, {:string, {:min, 1}}}, description: "Run id returned by workflow_start.")
  end

  @impl true
  def execute(%{run_id: run_id}, frame) when is_binary(run_id) do
    ToolHelpers.open_ui_tool(frame, run_id)
  end
end
