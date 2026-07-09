defmodule Workflow.MCPProjectionEnvelopeTest do
  use ExUnit.Case, async: true

  alias Workflow.MCP.ProjectionEnvelope

  @pinned_fields [
    "agentCount",
    "agents",
    "eventCount",
    "failure",
    "journalEvents",
    "judgments",
    "logs",
    "phase",
    "rawRefs",
    "refines",
    "rejected",
    "result",
    "state",
    "toolActivity",
    "treeName",
    "usage",
    "verifications",
    "runId"
  ]

  test "conform drops scheduler-only fields while keeping inspect journal summaries" do
    envelope = %{
      "api_version" => "scheduler.v1",
      "data" => %{
        "runId" => "run-public",
        "state" => "completed",
        "treeName" => "demo",
        "phase" => nil,
        "logs" => [],
        "agentCount" => 0,
        "eventCount" => 1,
        "usage" => %{"inputTokens" => 0, "outputTokens" => 0, "totalTokens" => 0},
        "result" => "ok",
        "failure" => nil,
        "agents" => [],
        "rejected" => [],
        "verifications" => [],
        "judgments" => [],
        "refines" => [],
        "toolActivity" => [],
        "journalEvents" => [%{"seq" => 0, "type" => "run_started"}],
        "rawRefs" => %{"journal" => [%{"runId" => "run-public", "seq" => 0}]},
        "workflowName" => "demo",
        "lifecycleAction" => %{"action" => "none"},
        "uiPath" => "/runs/run-public",
        "uiUrl" => "/runs/run-public",
        "events" => [%{"seq" => 0, "type" => "run_started", "rawCodexJsonl" => "{}"}]
      }
    }

    assert %{"data" => data} = ProjectionEnvelope.conform(envelope)
    assert Enum.sort(Map.keys(data)) == Enum.sort(@pinned_fields)
    refute Map.has_key?(data, "workflowName")
    refute Map.has_key?(data, "lifecycleAction")
    refute Map.has_key?(data, "uiPath")
    refute Map.has_key?(data, "uiUrl")
    refute Map.has_key?(data, "events")
    assert data["journalEvents"] == [%{"seq" => 0, "type" => "run_started"}]
  end
end
