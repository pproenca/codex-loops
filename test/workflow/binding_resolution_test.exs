defmodule Workflow.BindingResolutionTest do
  use ExUnit.Case, async: true

  alias Workflow.Provider.Usage
  alias Workflow.Node.Agent
  alias Workflow.Event

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

    assert {:ok, %{"echo" => "wanted"}} =
             apply(Workflow.BoundValue, :fold, [events, {:node, [3]}])
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
             apply(Workflow.BoundList, :fold, [events, {:map, [9]}])
  end
end
