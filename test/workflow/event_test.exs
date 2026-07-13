defmodule Workflow.EventTest do
  use ExUnit.Case, async: true

  alias Workflow.Event
  alias Workflow.Event.Payload
  alias Workflow.IdempotencyKey
  alias Workflow.Node.Refine
  alias Workflow.Provider.Activity
  alias Workflow.Refine.ReviewerDecision
  alias Workflow.Refine.RoleFailure
  alias Workflow.Refine.RoundDecision

  test "refine gate events require their journal input references" do
    node = %Refine{
      address: [0],
      input: nil,
      reviewers: [],
      reviser: nil,
      until: :unanimous,
      max_rounds: 1
    }

    assert_raise KeyError, fn ->
      Event.refine_gate_evaluated(node, :halt, {:path_non_empty, "/openFindings"},
        result: true,
        input_round: 0
      )
    end
  end

  test "oldest refine decisions hydrate flags and derived failures without changing v1 shape" do
    event =
      Event.normalize(%Event{
        type: :refine_round_decision,
        payload: %{
          address: [0],
          round: 0,
          consensus: false,
          approval_count: 1,
          total: 2,
          reviewer_decisions: [
            %{reviewer: :spec, reviewer_index: 0, approved: true, clear: true}
          ],
          artifact: "draft",
          role_failures: [
            %{
              address: [0],
              role: :reviewer,
              role_address: [0, 1, 1],
              reviewer: :runtime,
              attempts: 1,
              reason: :timeout,
              activity: [
                %{kind: "provider", label: "Runtime", summary: "timed out", status: "failed"}
              ]
            }
          ],
          future_payload_key: :preserved
        }
      })

    assert %Payload.RefineRoundDecision{failed_reviewers: [:runtime]} = event.payload
    assert [%ReviewerDecision{}] = event.payload.reviewer_decisions
    assert [%RoleFailure{activity: [%Activity{status: :failed}]}] = event.payload.role_failures

    assert %RoundDecision{
             reviewer_decisions: [
               %ReviewerDecision{reviewer: :spec, adapter: :findings_v1, outcome: :clear}
             ],
             failed_reviewers: [:runtime]
           } = Payload.RefineRoundDecision.decision(event.payload)

    persisted = Event.payload_map(event)
    assert Map.fetch!(persisted, :future_payload_key) == :preserved
    refute is_struct(hd(persisted.reviewer_decisions))
    refute is_struct(hd(persisted.role_failures))
    refute is_struct(hd(hd(persisted.role_failures).activity))

    refute Map.has_key?(persisted, :cold_read)
  end

  test "outcome-unknown identities hydrate internally and retain the version-one map" do
    run_id = "outcome_unknown_boundary"

    event =
      Event.normalize(%Event{
        run_id: run_id,
        type: :run_failed,
        payload: %{reason: {:outcome_unknown, %{address: [2], iteration: 3, attempt: 4}}}
      })

    assert event.payload.reason ==
             {:outcome_unknown, %IdempotencyKey{run_id: run_id, node_path: [2], iteration: 3, attempt: 4}}

    assert Event.payload_map(event) ==
             %{reason: {:outcome_unknown, %{address: [2], iteration: 3, attempt: 4}}}
  end
end
