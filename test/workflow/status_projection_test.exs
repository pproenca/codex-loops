defmodule Workflow.StatusProjectionTest do
  use ExUnit.Case, async: true

  alias Workflow.Event
  alias Workflow.IdempotencyKey
  alias Workflow.Node.Agent
  alias Workflow.Node.GenericFanout
  alias Workflow.Node.Loop
  alias Workflow.Node.Phase
  alias Workflow.Node.Refine
  alias Workflow.Provider.Activity
  alias Workflow.Provider.Usage
  alias Workflow.Refine.OpenFinding
  alias Workflow.Refine.Reviewer
  alias Workflow.Refine.ReviewerDecision
  alias Workflow.Refine.RoleFailure
  alias Workflow.Scheduler.RunProjection
  alias Workflow.Status
  alias Workflow.Tree

  defp activity_fields(%Activity{} = activity) do
    activity
    |> Map.from_struct()
    |> Map.delete(:activity_index)
  end

  defp activity_fields(activity) when is_map(activity) do
    activity
    |> Activity.normalize!()
    |> activity_fields()
  end

  defp normalized_activity_fields(activity), do: activity |> Activity.normalize!() |> activity_fields()

  test "durable progress activity updates the running agent and raw journal refs" do
    run_id = "status_projection_progress"
    node = %Agent{address: [1], prompt: "stream work", label: "stream:work"}
    key = %IdempotencyKey{run_id: run_id, node_path: [1], iteration: 0, attempt: 0}

    entry = %{
      kind: "reasoning",
      label: "Reasoning",
      summary: "thinking while running",
      status: "running"
    }

    journal_status =
      [
        Event.run_started(%Tree{name: "progress-status", nodes: [node]}),
        Event.phase_entered(%Phase{address: [0], name: "stream"}),
        Event.agent_started(node, 0, key),
        Event.agent_activity(node, 0, 0, 0, entry)
      ]
      |> stamp(run_id)
      |> Status.fold(run_id)

    assert journal_status.event_count == 4

    assert Enum.map(journal_status.raw_refs.journal, & &1.type) == [
             "run_started",
             "phase_entered",
             "agent_started",
             "agent_activity"
           ]

    assert [%{status: :running, activity: [agent_activity]}] = journal_status.agents
    assert activity_fields(agent_activity) == normalized_activity_fields(entry)

    assert [%{entry: tool_activity, raw_ref: %{seq: 3, type: "agent_activity"}}] =
             journal_status.tool_activity

    assert activity_fields(tool_activity) == normalized_activity_fields(entry)
  end

  test "late persisted activity merges into settled and rejected attempt projections" do
    run_id = "status_projection_late_activity"
    node = %Agent{address: [1], prompt: "stream work", label: "stream:work"}
    key = %IdempotencyKey{run_id: run_id, node_path: [1], iteration: 0, attempt: 0}
    usage = %Usage{input_tokens: 1, output_tokens: 2, total_tokens: 3}

    entry = %{
      kind: "reasoning",
      label: "Reasoning",
      summary: "arrived after settlement",
      status: "completed"
    }

    prefix = [
      Event.run_started(%Tree{name: "late-activity-status", nodes: [node]}),
      Event.phase_entered(%Phase{address: [0], name: "stream"})
    ]

    committed =
      (prefix ++
         [
           Event.agent_committed(node, 0, key, "done", usage, []),
           Event.agent_activity(node, 0, 0, 0, entry)
         ])
      |> stamp(run_id)
      |> Status.fold(run_id)

    assert [
             %{
               status: :completed,
               attempt: 0,
               result: "done",
               activity: [committed_activity]
             }
           ] = committed.agents

    assert activity_fields(committed_activity) == normalized_activity_fields(entry)

    rejected =
      (prefix ++
         [
           Event.agent_attempt_rejected(node, 0, 0, %{"bad" => true}, :invalid, usage, []),
           Event.agent_activity(node, 0, 0, 0, entry)
         ])
      |> stamp(run_id)
      |> Status.fold(run_id)

    assert rejected.agents == []

    assert [
             %{
               attempt: 0,
               reason: :invalid,
               activity: [rejected_activity]
             }
           ] = rejected.rejected

    assert activity_fields(rejected_activity) == normalized_activity_fields(entry)

    failed =
      (prefix ++
         [
           Event.agent_failed(node, 0, 1, :invalid, usage, []),
           Event.agent_activity(node, 0, 0, 0, entry)
         ])
      |> stamp(run_id)
      |> Status.fold(run_id)

    assert [
             %{
               status: :failed,
               attempt: 0,
               activity: [failed_activity]
             }
           ] = failed.agents

    assert failed.state == :failed
    assert activity_fields(failed_activity) == normalized_activity_fields(entry)
  end

  test "status folds refines, tool activity, and ordered raw journal refs" do
    run_id = "status_projection_refine"
    node = refine_node()
    cold_reader = node.gates.cold_read.reviewer.agent
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

    role_failure = %RoleFailure{
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
      stamp(
        [
          Event.run_started(%Tree{name: "refine-status", nodes: [node]}),
          node |> Event.refine_started() |> put_in([Access.key!(:payload), :future_payload_key], :ignored_by_status),
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
              %ReviewerDecision{
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
        ],
        run_id
      )

    status = Status.fold(events, run_id)
    started_event = Enum.find(events, &(&1.type == :refine_started))

    assert started_event.payload.review_schema_version == 1
    assert started_event.payload.future_payload_key == :ignored_by_status

    assert Enum.map(status.raw_refs.journal, & &1.seq) == Enum.to_list(0..9)

    assert Enum.map(status.raw_refs.journal, & &1.type) ==
             Enum.map(events, &Atom.to_string(&1.type))

    assert [
             %{entry: streamed_entry, raw_ref: %{seq: 3, type: "agent_activity"}},
             %{entry: committed_entry, raw_ref: %{seq: 4, type: "agent_committed"}},
             %{entry: failed_entry, raw_ref: %{seq: 5, type: "refine_role_failed"}}
           ] = status.tool_activity

    assert activity_fields(streamed_entry) == normalized_activity_fields(streamed_activity)
    assert activity_fields(committed_entry) == normalized_activity_fields(committed_activity)
    assert activity_fields(failed_entry) == normalized_activity_fields(failed_activity)

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
    assert Enum.map(envelope["rawRefs"]["journal"], & &1["seq"]) == Enum.to_list(0..9)
    assert Enum.map(envelope["toolActivity"], &get_in(&1, ["rawRef", "seq"])) == [3, 4, 5]

    assert [public_refine] = envelope["refines"]
    assert public_refine["rawRefs"]["started"]["seq"] == 1
    assert Enum.map(public_refine["rawRefs"]["gateRoleAgents"], & &1["seq"]) == [3, 4]
    assert Enum.map(public_refine["rawRefs"]["journal"], & &1["seq"]) == Enum.to_list(1..8)
  end

  test "status folds generic fanout failure as a terminal run failure" do
    run_id = "status_projection_fanout_failed"

    node = %GenericFanout{
      address: [0],
      width: 0,
      lanes: [[%Agent{address: [0], prompt: "never"}]],
      on_zero: :fail
    }

    events =
      stamp(
        [
          Event.run_started(%Tree{name: "fanout-status", nodes: [node]}),
          Event.fanout_started(node, 0, nil),
          Event.fanout_failed(node, :zero_width, nil)
        ],
        run_id
      )

    status = Status.fold(events, run_id)

    assert status.state == :failed

    assert status.failure == %{
             address: [0],
             iteration: nil,
             attempts: 0,
             reason: {:fanout_failed, [0], nil, :zero_width}
           }

    assert Enum.map(status.raw_refs.journal, & &1.type) == [
             "run_started",
             "fanout_started",
             "fanout_failed"
           ]
  end

  test "status folds loop exhaustion as a terminal run failure" do
    run_id = "status_projection_loop_exhausted"
    node = %Loop{address: [0], max_iterations: 1, body: [], on_exhausted: :fail}

    events =
      stamp(
        [
          Event.run_started(%Tree{name: "loop-status", nodes: [node]}),
          Event.loop_decision(node, 0, :continue, predicate_result: false, exhausted: false, source_address: nil),
          Event.iteration_started(node, 0),
          Event.loop_decision(node, 1, {:exhausted, :fail}, predicate_result: nil, exhausted: true, source_address: nil),
          Event.loop_exhausted(node, 1, :max_iterations)
        ],
        run_id
      )

    status = Status.fold(events, run_id)

    assert status.state == :failed

    assert status.failure == %{
             address: [0],
             iteration: 1,
             attempts: 0,
             reason: {:loop_exhausted, [0], 1}
           }

    assert Enum.map(status.raw_refs.journal, & &1.type) == [
             "run_started",
             "loop_decision",
             "iteration_started",
             "loop_decision",
             "loop_exhausted"
           ]
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
        %Reviewer{
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
          reviewer: %Reviewer{
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
    %OpenFinding{
      reviewer: :spec,
      reviewer_index: 0,
      id: "spec-gap",
      issue: "Spec is missing a boundary.",
      fix: "Define the boundary."
    }
  end
end
