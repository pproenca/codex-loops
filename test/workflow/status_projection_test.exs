defmodule Workflow.StatusProjectionTest do
  use ExUnit.Case, async: true

  alias Workflow.Provider.Usage
  alias Workflow.Scheduler.RunProjection
  alias Workflow.{Event, IdempotencyKey, Status, Tree}
  alias Workflow.Node.{Agent, Refine}

  test "status folds refines, tool activity, and ordered raw journal refs" do
    run_id = "status_projection_refine"
    node = refine_node()
    cold_reader = get_in(node.gates, [:cold_read, :reviewer, :agent])
    usage = %Usage{input_tokens: 2, output_tokens: 3, total_tokens: 5}

    streamed_activity = %{
      kind: "tool",
      label: "Cold read",
      summary: "reviewing the final artifact",
      status: "running"
    }

    committed_activity = %{
      kind: "tool",
      label: "Cold read",
      summary: "cold read completed",
      status: "completed"
    }

    failed_activity = %{
      kind: "provider",
      label: "Cold read",
      summary: "timed out",
      status: "failed"
    }

    role_failure = %{
      address: [0],
      role: :cold_read,
      role_address: [0, 3],
      round: 0,
      reviewer: :cold,
      reviewer_index: 0,
      attempts: 1,
      reason: {:cold_read_timeout, 100},
      detail: %{timeout_ms: 100},
      usage: usage,
      activity: [failed_activity]
    }

    events =
      [
        Event.run_started(%Tree{name: "refine-status", nodes: [node]}),
        Event.refine_started(node),
        Event.refine_round_started(node, 0, "draft-v1"),
        Event.agent_activity(cold_reader, 0, 0, 0, streamed_activity),
        Event.agent_committed(
          cold_reader,
          0,
          %IdempotencyKey{run_id: run_id, node_path: [0, 3], iteration: 0, attempt: 0},
          %{"approved" => false, "findings" => []},
          usage,
          [committed_activity]
        ),
        Event.refine_role_failed(role_failure),
        Event.refine_gate_evaluated(node, :cold_read, {:path_non_empty, "/openFindings"},
          result: true,
          input_round: 0,
          input_refs: []
        ),
        Event.refine_round_decision(node, 0, %{
          consensus: false,
          approval_count: 0,
          total: 1,
          reviewer_decisions: [
            %{
              reviewer: :spec,
              reviewer_index: 0,
              approved: false,
              clear: false,
              adapter: :findings_v1,
              status: :completed
            }
          ],
          artifact: "draft-v1",
          open_findings: [finding()],
          role_failures: [role_failure],
          failed_reviewers: [:cold],
          report_snippets: ["cold read timed out"]
        }),
        Event.refine_completed(node, %{
          converged: true,
          final_round: 0,
          rounds: 1,
          artifact: "draft-v2",
          open_findings: [],
          role_failures: [role_failure],
          failed_reviewers: [:cold],
          report_snippets: ["cold read timed out"]
        }),
        Event.run_completed("draft-v2")
      ]
      |> stamp(run_id)

    status = Status.fold(events, run_id)

    assert Enum.map(status.raw_refs.journal, & &1.seq) == Enum.to_list(0..9)

    assert Enum.map(status.raw_refs.journal, & &1.type) ==
             Enum.map(events, &Atom.to_string(&1.type))

    assert [
             %{entry: streamed_entry, raw_ref: %{seq: 3, type: "agent_activity"}},
             %{entry: committed_entry, raw_ref: %{seq: 4, type: "agent_committed"}},
             %{entry: failed_entry, raw_ref: %{seq: 5, type: "refine_role_failed"}}
           ] = status.tool_activity

    assert Map.drop(streamed_entry, [:activity_index]) == streamed_activity
    assert Map.drop(committed_entry, [:activity_index]) == committed_activity
    assert Map.drop(failed_entry, [:activity_index]) == failed_activity

    assert [refine] = status.refines
    assert refine.address == [0]
    assert refine.state == :completed
    assert refine.converged == true
    assert refine.rounds == 1
    assert refine.failed_reviewers == [:cold]
    assert refine.role_failures == [role_failure]
    assert refine.artifact_preview == "draft-v2"

    assert refine.raw_refs.started.seq == 1
    assert Enum.map(refine.raw_refs.rounds, & &1.seq) == [2]
    assert Enum.map(refine.raw_refs.gate_role_agents, & &1.seq) == [3, 4]
    assert Enum.map(refine.raw_refs.role_failures, & &1.seq) == [5]
    assert Enum.map(refine.raw_refs.gates, & &1.seq) == [6]
    assert Enum.map(refine.raw_refs.decisions, & &1.seq) == [7]
    assert refine.raw_refs.terminal.seq == 8
    assert Enum.map(refine.raw_refs.journal, & &1.seq) == Enum.to_list(1..8)

    envelope =
      status
      |> RunProjection.from_status()
      |> RunProjection.to_map()

    assert envelope["runId"] == run_id
    assert envelope["treeName"] == "refine-status"
    assert envelope["agentCount"] == 1
    assert envelope["eventCount"] == 10
    assert envelope["rawRefs"]["journal"] |> Enum.map(& &1["seq"]) == Enum.to_list(0..9)
    assert envelope["toolActivity"] |> Enum.map(&get_in(&1, ["rawRef", "seq"])) == [3, 4, 5]

    assert [public_refine] = envelope["refines"]
    assert public_refine["rawRefs"]["started"]["seq"] == 1
    assert public_refine["rawRefs"]["gateRoleAgents"] |> Enum.map(& &1["seq"]) == [3, 4]
    assert public_refine["rawRefs"]["journal"] |> Enum.map(& &1["seq"]) == Enum.to_list(1..8)
  end

  defp stamp(events, run_id) do
    events
    |> Enum.with_index()
    |> Enum.map(fn {event, seq} -> %{event | run_id: run_id, seq: seq} end)
  end

  defp refine_node do
    producer = %Agent{address: [0, 0], prompt: "Draft."}
    reviewer = %Agent{address: [0, 1, 0], prompt: "Review.", retries: 2}
    reviser = %Agent{address: [0, 2], prompt: "Revise.", retries: 2}
    cold_reader = %Agent{address: [0, 3], prompt: "Cold read.", retries: 2}
    repairer = %Agent{address: [0, 4], prompt: "Repair.", retries: 2}

    %Refine{
      address: [0],
      input: {:producer, producer},
      reviewers: [
        %{
          index: 0,
          name: :spec,
          prompt: "Review.",
          adapter: :findings_v1,
          agent: reviewer
        }
      ],
      reviser: reviser,
      until: :unanimous,
      max_rounds: 2,
      gates: %{
        cold_read: %{
          predicate: {:path_non_empty, "/openFindings"},
          reviewer: %{
            index: 0,
            name: :cold,
            prompt: "Cold read.",
            adapter: :findings_v1,
            agent: cold_reader
          }
        },
        repair: %{predicate: {:path_non_empty, "/openFindings"}, agent: repairer},
        halt: %{predicate: {:path_count, "/openFindings", :>, 3}}
      }
    }
  end

  defp finding do
    %{
      reviewer: :spec,
      reviewer_index: 0,
      id: "spec-gap",
      issue: "Spec is missing a boundary.",
      fix: "Define the boundary."
    }
  end
end
