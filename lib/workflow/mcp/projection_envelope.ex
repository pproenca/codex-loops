defmodule Workflow.MCP.ProjectionEnvelope do
  @moduledoc false

  @run_projection_fields [
    "runId",
    "state",
    "treeName",
    "phase",
    "logs",
    "agentCount",
    "eventCount",
    "usage",
    "result",
    "failure",
    "agents",
    "rejected",
    "verifications",
    "judgments",
    "refines",
    "toolActivity",
    "rawRefs"
  ]

  @spec conform(map()) :: map()
  def conform(%{"api_version" => _version, "data" => data} = envelope) when is_map(data) do
    %{envelope | "data" => Map.take(data, @run_projection_fields)}
  end

  def conform(envelope), do: envelope
end
