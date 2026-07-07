defmodule Workflow.RenderTextTest do
  use ExUnit.Case, async: true

  alias Workflow.Provider.Usage
  alias Workflow.Node.Agent
  alias Workflow.Event

  test "renders literal prompt fragments with the existing byte shape" do
    assert Code.ensure_loaded?(Workflow.RenderText)

    assert {:ok, verify_prompt} =
             apply(Workflow.RenderText, :fold, [
               [],
               [
                 {:text, "Confirm or refute this finding, answering with a boolean verdict: "},
                 {:literal, "finding"}
               ]
             ])

    assert verify_prompt ==
             "Confirm or refute this finding, answering with a boolean verdict: finding"

    assert {:ok, judge_prompt} =
             apply(Workflow.RenderText, :fold, [
               [],
               [
                 {:text, "Score this candidate on feasibility, answering with a numeric score: "},
                 {:literal, "plan A"}
               ]
             ])

    assert judge_prompt ==
             "Score this candidate on feasibility, answering with a numeric score: plan A"

    assert {:ok, synthesize_prompt} =
             apply(Workflow.RenderText, :fold, [
               [],
               [
                 {:text, "Write up the winning plan."},
                 {:text, "\n\nInputs: "},
                 {:literal, ["plan A", "plan B", "plan C"]}
               ]
             ])

    assert synthesize_prompt ==
             "Write up the winning plan.\n\nInputs: [\"plan A\", \"plan B\", \"plan C\"]"
  end

  test "renders bound node and map references from a hand-built journal" do
    assert Code.ensure_loaded?(Workflow.RenderText)

    events = [
      Event.agent_committed(
        %Agent{address: [2], prompt: "single"},
        0,
        :single,
        %{"echo" => "one"},
        %Usage{}
      ),
      Event.agent_committed(
        %Agent{address: [4, 0], prompt: "lane 0"},
        0,
        :lane0,
        %{"echo" => "alpha"},
        %Usage{}
      ),
      Event.agent_committed(
        %Agent{address: [4, 1], prompt: "lane 1"},
        0,
        :lane1,
        %{"echo" => "beta"},
        %Usage{}
      )
    ]

    assert {:ok, rendered} =
             apply(Workflow.RenderText, :fold, [
               events,
               [
                 {:text, "Single: "},
                 {:bound_value, {:node, [2]}},
                 {:text, "\nMany: "},
                 {:bound_list, {:map, [4]}}
               ]
             ])

    assert rendered ==
             ~s|Single: %{"echo" => "one"}\nMany: [%{"echo" => "alpha"}, %{"echo" => "beta"}]|
  end
end
