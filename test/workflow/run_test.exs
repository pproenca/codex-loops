defmodule Workflow.RunTest do
  @moduledoc """
  Run semantics over the inert tree, driven through the interpreter with a
  call-counting mock provider. Assertions are on external behaviour: the committed
  journal and the folded read model.
  """
  use ExUnit.Case, async: true

  alias Workflow.{Run, Journal, Status, IdempotencyKey, Idempotency, Event}
  alias Workflow.Provider.Usage
  alias Workflow.Test.{EchoProvider, GateProvider}

  defmodule DemoWorkflow do
    use Workflow

    workflow "demo" do
      phase("p")
      log("hi")
      agent("say hello")
      return(:ok)
    end
  end

  defp run_id, do: "run_#{System.unique_integer([:positive])}"
  defp echo, do: {EchoProvider, [sink: self()]}

  test "runs the demo end-to-end, committing ordered events and completing" do
    id = run_id()

    assert {:ok, ^id} = Run.run(DemoWorkflow, run_id: id, provider: echo())

    # The provider ran exactly once.
    assert_received {:agent_called, "say hello"}
    refute_received {:agent_called, _}

    events = Journal.fold(id)

    assert Enum.map(events, & &1.type) ==
             [:run_started, :phase_entered, :log_emitted, :agent_committed, :run_completed]

    # seq is contiguous and ordered.
    assert Enum.map(events, & &1.seq) == [0, 1, 2, 3, 4]

    # Every event is versioned.
    assert Enum.all?(events, &(&1.schema == Event.schema_version()))
  end

  test "each agent event records usage, a stable address, and the idempotency key" do
    id = run_id()
    {:ok, ^id} = Run.run(DemoWorkflow, run_id: id, provider: echo())

    agent = Enum.find(Journal.fold(id), &(&1.type == :agent_committed))

    assert agent.payload.address == [2]
    assert agent.payload.iteration == 0
    assert %Usage{total_tokens: 8} = agent.payload.usage

    assert agent.payload.idempotency_key ==
             %IdempotencyKey{run_id: id, node_path: [2], iteration: 0}
  end

  test "status reconstructs run state purely by folding the journal" do
    id = run_id()
    {:ok, ^id} = Run.run(DemoWorkflow, run_id: id, provider: echo())

    status = Status.of(id)

    assert status.state == :completed
    assert status.result == :ok
    assert status.tree_name == "demo"
    assert status.phase == "p"
    assert status.logs == ["hi"]
    assert length(status.agents) == 1
    assert status.usage.total_tokens == 8
    assert status.event_count == 5

    # Purity: folding the same events by hand yields the same model.
    assert Status.fold(Journal.fold(id), id) == status
  end

  test "a post-commit broadcast fires on every committed event" do
    id = run_id()
    :ok = Phoenix.PubSub.subscribe(Workflow.PubSub, "run:" <> id)

    {:ok, ^id} = Run.run(DemoWorkflow, run_id: id, provider: echo())

    assert_receive {:journal_committed, ^id, %Event{type: :run_started}}
    assert_receive {:journal_committed, ^id, %Event{type: :phase_entered}}
    assert_receive {:journal_committed, ^id, %Event{type: :log_emitted}}
    assert_receive {:journal_committed, ^id, %Event{type: :agent_committed}}
    assert_receive {:journal_committed, ^id, %Event{type: :run_completed}}
  end

  test "exactly-once: a committed agent effect is replayed from the journal, not re-run" do
    committed =
      Event.agent_committed(
        %Workflow.Node.Agent{address: [2], prompt: "say hello"},
        0,
        %IdempotencyKey{run_id: "r", node_path: [2], iteration: 0},
        %{"echo" => "cached"},
        %Usage{total_tokens: 8}
      )

    assert {:committed, %{"echo" => "cached"}, %Usage{total_tokens: 8}} =
             Idempotency.resolve([committed], [2], 0)

    assert :none = Idempotency.resolve([], [2], 0)
    assert :none = Idempotency.resolve([committed], [9], 0)
  end

  test "one live writer per run: a second start for the same run_id is rejected" do
    id = run_id()
    provider = {GateProvider, [sink: self()]}

    {:ok, ^id, pid} = Run.start(DemoWorkflow, run_id: id, provider: provider)

    # The writer is now blocked inside the agent turn, holding the lease.
    assert_receive {:at_agent, agent_pid}

    assert {:error, {:already_running, ^pid}} =
             Run.start(DemoWorkflow, run_id: id, provider: provider)

    # Release the turn and let the run finish; the lease is freed on exit.
    ref = Process.monitor(pid)
    send(agent_pid, :proceed)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
  end
end
