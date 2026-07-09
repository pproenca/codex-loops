defmodule Workflow.MCP.AnubisServer do
  @moduledoc """
  Anubis-backed MCP server used by the packaged `codex-loops-mcp` executable.

  The server owns MCP protocol handling and delegates scheduler work through the
  HTTP client helpers so the MCP surface stays outside scheduler internals.
  """

  use Anubis.Server,
    name: "codex-loops",
    version: "0.1.0",
    capabilities: [:tools]

  alias Workflow.MCP.AnubisServer.ToolHelpers

  component(Workflow.MCP.AnubisServer.WorkflowValidate)
  component(Workflow.MCP.AnubisServer.WorkflowStart)
  component(Workflow.MCP.AnubisServer.WorkflowStatus)
  component(Workflow.MCP.AnubisServer.WorkflowInspect)
  component(Workflow.MCP.AnubisServer.WorkflowResume)
  component(Workflow.MCP.AnubisServer.WorkflowOpenUI)

  @impl true
  def init(_client_info, frame) do
    {:ok, ToolHelpers.init_lifecycle(frame)}
  end

  @impl true
  def terminate(_reason, frame) do
    ToolHelpers.stop_lifecycle(frame)
  end
end
