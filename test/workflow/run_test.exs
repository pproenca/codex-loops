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

  defmodule ActivityProvider do
    @behaviour Workflow.Provider

    @impl true
    def run_agent(prompt, _schema, _key, opts) do
      if sink = Keyword.get(opts, :sink), do: send(sink, {:agent_called, prompt})

      activity = [
        %{
          kind: "tool",
          label: "Shell",
          summary: "mix test test/workflow/run_test.exs",
          status: "completed"
        }
      ]

      {:ok, %{"echo" => prompt}, %Usage{input_tokens: 2, output_tokens: 3, total_tokens: 5},
       activity}
    end
  end

  defmodule StreamingActivityProvider do
    @behaviour Workflow.Provider

    @impl true
    def run_agent(prompt, _schema, _key, opts) do
      entry = %{
        kind: "tool",
        label: "Shell",
        summary: "mix test test/workflow/run_test.exs",
        status: "completed"
      }

      Keyword.fetch!(opts, :activity_sink).(entry)

      {:ok, %{"echo" => prompt}, %Usage{input_tokens: 2, output_tokens: 3, total_tokens: 5}, []}
    end
  end

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

  test "richer provider tuples journal normalized activity on committed agents" do
    id = run_id()

    assert {:ok, ^id} =
             Run.run(DemoWorkflow, run_id: id, provider: {ActivityProvider, sink: self()})

    agent = Enum.find(Journal.fold(id), &(&1.type == :agent_committed))

    assert Enum.map(agent.payload.activity, &Map.delete(&1, :activity_index)) == [
             %{
               kind: "tool",
               label: "Shell",
               summary: "mix test test/workflow/run_test.exs",
               status: "completed"
             }
           ]

    [folded_agent] = Status.of(id).agents
    assert folded_agent.activity == agent.payload.activity
  end

  test "streamed activity before a settled event uses the serialized append allocator" do
    id = run_id()

    assert {:ok, ^id} =
             Run.run(DemoWorkflow, run_id: id, provider: {StreamingActivityProvider, []})

    events = Journal.fold(id)

    assert Enum.map(events, & &1.type) == [
             :run_started,
             :phase_entered,
             :log_emitted,
             :agent_activity,
             :agent_committed,
             :run_completed
           ]

    assert Enum.map(events, & &1.seq) == Enum.to_list(0..5)
  end

  test "activity replay is idempotent by activity index and preserves repeated entries" do
    id = run_id()
    node = %Workflow.Node.Agent{address: [0], prompt: "inspect"}
    entry = %{kind: "tool", label: "Shell", summary: "mix test", status: "completed"}

    :ok =
      Journal.append(id, 0, %{
        Event.run_started(%Workflow.Tree{name: "t", nodes: []})
        | run_id: id,
          seq: 0
      })

    assert {:ok, first} = Journal.append_next(id, Event.agent_activity(node, 0, 0, 0, entry))
    assert {:ok, replayed} = Journal.append_next(id, Event.agent_activity(node, 0, 0, 0, entry))
    assert {:ok, second} = Journal.append_next(id, Event.agent_activity(node, 0, 0, 1, entry))

    assert first.seq == replayed.seq
    assert second.seq == first.seq + 1

    status = Status.of(id)
    assert [%{activity: [first_entry, second_entry]}] = status.agents
    assert Map.drop(first_entry, [:activity_index]) == entry
    assert Map.drop(second_entry, [:activity_index]) == entry
    assert first_entry.activity_index == 0
    assert second_entry.activity_index == 1
  end

  test "status attributes interleaved retry activity to the matching attempt" do
    node = %Workflow.Node.Agent{address: [0], prompt: "classify"}
    usage = %Usage{input_tokens: 1, output_tokens: 1, total_tokens: 2}

    attempt_0_activity = %{
      kind: "tool",
      label: "Validator",
      summary: "attempt 0 validation",
      status: "rejected"
    }

    attempt_1_activity = %{
      kind: "tool",
      label: "Shell",
      summary: "attempt 1 retry",
      status: "running"
    }

    events = [
      Event.agent_activity(node, 0, 1, 0, attempt_1_activity),
      Event.agent_attempt_rejected(
        node,
        0,
        0,
        %{"bad" => true},
        {:missing_required, "label"},
        usage,
        [attempt_0_activity]
      )
    ]

    status = Status.fold(events, "r")

    assert [
             %{
               attempt: 0,
               activity: [rejected_activity]
             }
           ] = status.rejected

    assert Map.drop(rejected_activity, [:activity_index]) == attempt_0_activity

    assert [
             %{
               attempt: 1,
               status: :running,
               activity: [in_flight_activity]
             }
           ] = status.agents

    assert Map.drop(in_flight_activity, [:activity_index]) == attempt_1_activity
  end

  test "agent events journal workflow-authored labels into the folded read model" do
    node = %Workflow.Node.Agent{address: [0], prompt: "inspect docs", label: "read:docs"}

    committed =
      Event.agent_committed(
        node,
        0,
        %IdempotencyKey{run_id: "r", node_path: [0], iteration: 0},
        %{"label" => "ok"},
        %Usage{total_tokens: 1}
      )

    status = Status.fold([committed], "r")

    assert committed.payload.label == "read:docs"
    assert [%{label: "read:docs"}] = status.agents
  end

  test "legacy committed and rejected agent events fold with empty activity" do
    node = %Workflow.Node.Agent{address: [0], prompt: "classify"}

    committed =
      Event.agent_committed(
        node,
        0,
        %IdempotencyKey{run_id: "r", node_path: [0], iteration: 0},
        %{"label" => "ok"},
        %Usage{total_tokens: 1}
      )

    rejected =
      Event.agent_attempt_rejected(
        node,
        0,
        0,
        %{"bad" => true},
        "missing label",
        %Usage{total_tokens: 1}
      )

    status = Status.fold([committed, rejected], "r")

    assert status.agents == []
    assert [%{activity: []}] = status.rejected
  end

  test "a legacy literal-prompt agent still sends and journals the exact binary prompt" do
    id = run_id()

    assert {:ok, ^id} = Run.run(DemoWorkflow, run_id: id, provider: echo())

    assert_received {:agent_called, "say hello"}
    refute_received {:agent_called, _}

    committed = Enum.find(Journal.fold(id), &(&1.type == :agent_committed))
    assert committed.payload.prompt == "say hello"
    assert is_binary(committed.payload.prompt)
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

  test "status groups agents under the latest entered phase with an implicit default phase" do
    usage = %Usage{input_tokens: 1, output_tokens: 1, total_tokens: 2}
    key = %IdempotencyKey{run_id: "r", node_path: [0], iteration: 0}

    events = [
      Event.agent_committed(
        %Workflow.Node.Agent{address: [0], prompt: "preflight"},
        0,
        key,
        :preflight,
        usage
      ),
      Event.phase_entered(%Workflow.Node.Phase{address: [1], name: "plan"}),
      Event.agent_committed(
        %Workflow.Node.Agent{address: [2], prompt: "plan"},
        0,
        key,
        :plan,
        usage
      ),
      Event.phase_entered(%Workflow.Node.Phase{address: [3], name: "build"}),
      Event.agent_committed(
        %Workflow.Node.Agent{address: [4], prompt: "build"},
        0,
        key,
        :build,
        usage
      )
    ]

    status = Status.fold(events, "r")

    assert Enum.map(status.phases, & &1.name) == ["Default phase", "plan", "build"]

    assert [
             %{id: "phase-default", agents: [%{prompt: "preflight", phase_id: "phase-default"}]},
             %{id: "phase-1", agents: [%{prompt: "plan", phase_id: "phase-1"}]},
             %{id: "phase-2", agents: [%{prompt: "build", phase_id: "phase-2"}]}
           ] = status.phases
  end

  test "status keeps same-address loop agents distinct by iteration" do
    usage = %Usage{input_tokens: 1, output_tokens: 1, total_tokens: 2}
    node = %Workflow.Node.Agent{address: [1], prompt: "loop work"}

    events = [
      Event.phase_entered(%Workflow.Node.Phase{address: [0], name: "loop"}),
      Event.agent_attempt_rejected(
        node,
        0,
        0,
        %{"bad" => 0},
        {:missing_required, "label"},
        usage
      ),
      Event.agent_committed(
        node,
        0,
        %IdempotencyKey{run_id: "r", node_path: [1], iteration: 0},
        %{"label" => "zero"},
        usage
      ),
      Event.agent_attempt_rejected(
        node,
        1,
        0,
        %{"bad" => 1},
        {:missing_required, "label"},
        usage
      ),
      Event.agent_committed(
        node,
        1,
        %IdempotencyKey{run_id: "r", node_path: [1], iteration: 1},
        %{"label" => "one"},
        usage
      )
    ]

    status = Status.fold(events, "r")

    assert Enum.map(status.agents, &{&1.address, &1.iteration, &1.result}) == [
             {[1], 0, %{"label" => "zero"}},
             {[1], 1, %{"label" => "one"}}
           ]

    assert Enum.map(status.rejected, &{&1.address, &1.iteration, &1.attempt}) == [
             {[1], 0, 0},
             {[1], 1, 0}
           ]
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
