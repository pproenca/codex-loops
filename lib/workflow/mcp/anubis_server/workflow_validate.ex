defmodule Workflow.MCP.AnubisServer.WorkflowValidate do
  @moduledoc "Validate a Codex Loops workflow script through the local scheduler API."

  use Anubis.Server.Component, type: :tool, name: "workflow_validate"

  alias Workflow.MCP.{AnubisServer.ToolHelpers, SchedulerClient}

  schema do
    field(:script_path, {:required, :string},
      description: "Path to the workflow .exs file to validate."
    )
  end

  @impl true
  def execute(%{script_path: script_path}, frame) when is_binary(script_path) do
    ToolHelpers.scheduler_tool(frame, fn -> SchedulerClient.validate_workflow(script_path) end)
  end
end
