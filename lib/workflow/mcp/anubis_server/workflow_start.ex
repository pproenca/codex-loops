defmodule Workflow.MCP.AnubisServer.WorkflowStart do
  @moduledoc "Start a Codex Loops workflow run through POST /api/runs."

  use Anubis.Server.Component, type: :tool, name: "workflow_start"

  alias Workflow.MCP.{AnubisServer.ToolHelpers, SchedulerClient}

  @allowed_keys [:script_path, :run_id, :provider, :budget]

  schema do
    field(:script_path, {:required, :string},
      description: "Path to the workflow .exs file to run."
    )

    field(:run_id, :string,
      description: "Optional route-safe run id to preserve across status and UI links."
    )

    field(:provider, {:enum, ["mock", "codex"]},
      description:
        "Optional scheduler provider. Defaults to mock; codex spends a real Codex turn."
    )

    field(:budget, {:integer, {:gte, 0}}, description: "Optional non-negative scheduler budget.")
  end

  @impl true
  def execute(%{script_path: script_path} = arguments, frame) when is_binary(script_path) do
    attrs = arguments |> Map.take(@allowed_keys) |> stringify_keys()
    ToolHelpers.scheduler_tool(frame, fn -> SchedulerClient.start_run(attrs) end)
  end

  defp stringify_keys(map) do
    Map.new(map, fn {key, value} -> {Atom.to_string(key), value} end)
  end
end
