defmodule Workflow.RunInspectorTest do
  use ExUnit.Case, async: true

  alias Workflow.{Event, IdempotencyKey, RunInspector, Status}
  alias Workflow.Provider.Usage

  defp usage, do: %Usage{input_tokens: 1, output_tokens: 1, total_tokens: 2}
  defp agent_node, do: %Workflow.Node.Agent{address: [1], prompt: "loop work"}

  test "projects phase-scoped agents by address plus iteration with normalized activity" do
    events = [
      Event.phase_entered(%Workflow.Node.Phase{address: [0], name: "loop"}),
      Event.agent_attempt_rejected(
        agent_node(),
        0,
        0,
        %{"bad" => 0},
        {:missing_required, "label"},
        usage(),
        [
          %{
            "kind" => "tool",
            "label" => "Validator",
            "summary" => "first rejection",
            "status" => "rejected"
          }
        ]
      ),
      Event.agent_committed(
        agent_node(),
        0,
        %IdempotencyKey{run_id: "r", node_path: [1], iteration: 0},
        %{"label" => "zero"},
        usage(),
        [%{kind: :reasoning, label: "Reasoning", summary: "checked zero", status: "completed"}]
      ),
      Event.agent_attempt_rejected(
        agent_node(),
        1,
        0,
        %{"bad" => 1},
        {:missing_required, "label"},
        usage(),
        [%{kind: "tool", label: "Validator", summary: "second rejection", status: "rejected"}]
      ),
      Event.agent_committed(
        agent_node(),
        1,
        %IdempotencyKey{run_id: "r", node_path: [1], iteration: 1},
        %{"label" => "one"},
        usage()
      )
    ]

    projection = events |> Status.fold("r") |> RunInspector.from_status()

    assert [%{id: "phase-0", name: "loop", agents: [first, second]}] = projection.phases

    assert {first.id, first.address, first.iteration, first.outcome} ==
             {"agent-1-i0", [1], 0, %{"label" => "zero"}}

    assert {second.id, second.address, second.iteration, second.outcome} ==
             {"agent-1-i1", [1], 1, %{"label" => "one"}}

    assert first.activity == [
             %{
               kind: "reasoning",
               label: "Reasoning",
               summary: "checked zero",
               status: "completed"
             }
           ]

    assert Enum.map(projection.rejected_attempts, &{&1.address, &1.iteration, &1.attempt}) ==
             [{[1], 0, 0}, {[1], 1, 0}]

    selection = RunInspector.selection(projection)
    assert selection == %{focused_phase_id: "phase-0", selected_agent_id: "agent-1-i0"}

    first_detail =
      RunInspector.detail(projection, selection.focused_phase_id, selection.selected_agent_id)

    assert first_detail.agent.id == "agent-1-i0"

    assert [%{activity: [%{label: "Validator", summary: "first rejection"}]}] =
             first_detail.rejected_attempts

    second_detail = RunInspector.detail(projection, "phase-0", "agent-1-i1")

    assert second_detail.agent.id == "agent-1-i1"

    assert [%{activity: [%{label: "Validator", summary: "second rejection"}]}] =
             second_detail.rejected_attempts
  end

  test "keeps failed rejected-only attempts visible in the projected detail model" do
    events = [
      Event.phase_entered(%Workflow.Node.Phase{address: [0], name: "loop"}),
      Event.agent_committed(
        agent_node(),
        0,
        %IdempotencyKey{run_id: "r", node_path: [1], iteration: 0},
        %{"label" => "zero"},
        usage()
      ),
      Event.agent_attempt_rejected(
        agent_node(),
        1,
        0,
        %{"bad" => 1},
        {:missing_required, "label"},
        usage(),
        [
          %{
            kind: "tool",
            label: "Validator",
            summary: "failed iteration rejection",
            status: "rejected"
          }
        ]
      ),
      Event.agent_failed(agent_node(), 1, 1, {:missing_required, "label"})
    ]

    projection = events |> Status.fold("r") |> RunInspector.from_status()

    assert [%{address: [1], iteration: 1, attempt: 0}] = projection.failed_rejected_attempts

    detail = RunInspector.detail(projection, "phase-0", "agent-1-i0")

    assert detail.agent.id == "agent-1-i0"
    assert detail.rejected_attempts == []

    assert [
             %{
               address: [1],
               iteration: 1,
               attempt: 0,
               activity: [%{label: "Validator", summary: "failed iteration rejection"}]
             }
           ] = detail.failed_rejected_attempts
  end
end
