defmodule Workflow.BindingResolutionTest do
  use ExUnit.Case, async: true

  alias Workflow.Event
  alias Workflow.Node.Agent
  alias Workflow.Node.GenericFanout
  alias Workflow.Provider.Usage

  test "bound value folds a committed node result from a hand-built journal" do
    assert Code.ensure_loaded?(Workflow.BoundValue)

    events = [
      Event.agent_committed(
        %Agent{address: [1], prompt: "first"},
        0,
        :first,
        %{"echo" => "old"},
        %Usage{}
      ),
      Event.agent_committed(
        %Agent{address: [3], prompt: "target"},
        0,
        :target,
        %{"echo" => "wanted"},
        %Usage{}
      )
    ]

    assert {:ok, %{"echo" => "wanted"}} = Workflow.BoundValue.fold(events, {:node, [3]})
  end

  test "bound value folds a completed refine artifact from a hand-built journal" do
    assert Code.ensure_loaded?(Workflow.BoundValue)

    events = [
      %Event{
        type: :refine_completed,
        payload: %{
          address: [2],
          converged: true,
          final_round: 1,
          rounds: 2,
          artifact: "accepted spec",
          open_findings: []
        }
      }
    ]

    assert {:ok, "accepted spec"} = Workflow.BoundValue.fold(events, {:refine, [2]})
  end

  test "bound list folds ordered lane results for a map reference from a hand-built journal" do
    assert Code.ensure_loaded?(Workflow.BoundList)

    events = [
      Event.agent_committed(
        %Agent{address: [9, 0], prompt: "lane 0"},
        0,
        :lane0,
        %{"echo" => "alpha"},
        %Usage{}
      ),
      Event.agent_committed(
        %Agent{address: [9, 1], prompt: "lane 1"},
        0,
        :lane1,
        %{"echo" => "beta"},
        %Usage{}
      )
    ]

    assert {:ok, [%{"echo" => "alpha"}, %{"echo" => "beta"}]} =
             Workflow.BoundList.fold(events, {:map, [9]})
  end

  test "bound list folds ordered lane results for a fanout reference from journal markers" do
    assert Code.ensure_loaded?(Workflow.BoundList)

    fanout = %GenericFanout{
      address: [4],
      width: 2,
      lanes: [[%Agent{address: [4], prompt: "lane"}]],
      bind: :reviews
    }

    events = [
      Event.fanout_started(fanout, 2),
      Event.agent_committed(
        %Agent{address: [4, 1, 0], prompt: "lane 1"},
        0,
        :lane1,
        %{"echo" => "beta"},
        %Usage{}
      ),
      Event.agent_committed(
        %Agent{address: [4, 0, 0], prompt: "lane 0 draft"},
        0,
        :lane0_draft,
        %{"echo" => "draft"},
        %Usage{}
      ),
      Event.agent_committed(
        %Agent{address: [4, 0, 1], prompt: "lane 0 final"},
        0,
        :lane0_final,
        %{"echo" => "alpha"},
        %Usage{}
      )
    ]

    assert {:ok, [%{"echo" => "alpha"}, %{"echo" => "beta"}]} =
             Workflow.BoundList.fold(events, {:fanout, [4], :global})
  end

  test "bound list resolves a zero-width fanout binding to an empty list" do
    fanout = %GenericFanout{
      address: [4],
      width: 0,
      lanes: [[%Agent{address: [4], prompt: "lane"}]],
      bind: :reviews
    }

    assert {:ok, []} =
             Workflow.BoundList.fold(
               [Event.fanout_started(fanout, 0)],
               {:fanout, [4], :global}
             )
  end
end
