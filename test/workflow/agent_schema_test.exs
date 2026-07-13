defmodule Workflow.AgentSchemaTest do
  @moduledoc """
  Fail-closed structured-output semantics, driven through the interpreter over an
  inert tree with a call-counting, scripted mock provider. Every assertion is on
  external behaviour: the number of provider calls, the committed journal, and the
  read model folded from it.
  """
  use ExUnit.Case, async: true

  alias Workflow.IdempotencyKey
  alias Workflow.Journal
  alias Workflow.Provider.Activity
  alias Workflow.Provider.Usage
  alias Workflow.Run
  alias Workflow.Status
  alias Workflow.Test.DedupingProvider
  alias Workflow.Test.ExplodingProvider
  alias Workflow.Test.FlakyProvider
  alias Workflow.Test.ProviderFailureProvider
  alias Workflow.Test.ScriptedProvider

  # A workflow with a single schema-backed agent requiring an object with "label".
  defmodule Classify do
    @moduledoc false

    def tree do
      Workflow.Test.tree!(
        "classify",
        quote do
          agent("classify",
            schema: %{"type" => "object", "required" => ["label"]},
            retries: 2
          )

          return(:ok)
        end,
        __ENV__
      )
    end
  end

  defmodule InjectedClassify do
    @moduledoc false

    def tree do
      Workflow.Test.tree!(
        "injected-classify",
        quote do
          let(:draft = agent("draft"))

          agent(~P"classify: <%= @draft %>",
            schema: %{"type" => "object", "required" => ["label"]},
            retries: 1
          )

          return(:ok)
        end,
        __ENV__
      )
    end
  end

  defp run_id, do: "run_#{System.unique_integer([:positive])}"

  defp provider(outputs) do
    {:ok, script} = ScriptedProvider.start(outputs)
    {ScriptedProvider, sink: self(), script: script}
  end

  defp types(id) do
    id
    |> Journal.fold()
    |> Enum.reject(&(&1.type in [:agent_started, :agent_activity]))
    |> Enum.map(& &1.type)
  end

  defp activity_fields(%Activity{} = activity) do
    activity
    |> Map.from_struct()
    |> Map.delete(:activity_index)
  end

  test "a schema-backed agent returns a validated term through the mock provider" do
    id = run_id()
    valid = %{"label" => "spam", "confidence" => 9}

    assert {:ok, ^id} = Run.run(Classify.tree(), run_id: id, provider: provider([valid]))

    # The first output conforms, so the run makes one provider call.
    assert_received {:agent_called, "classify"}
    refute_received {:agent_called, _}

    committed = Enum.find(Journal.fold(id), &(&1.type == :agent_committed))
    assert committed.payload.result == valid
    assert committed.payload.address == [0]

    assert types(id) == [:run_started, :agent_committed, :run_completed]
    assert Status.of(id).state == :completed
  end

  test "schema-backed agents journal expected provider failures without schema retries" do
    id = run_id()
    detail = %{"code" => 429, "retry_after_ms" => 1_000}
    usage_map = %{"input_tokens" => 2, "output_tokens" => 0, "total_tokens" => 2}
    usage = %Usage{input_tokens: 2, output_tokens: 0, total_tokens: 2}

    activity = [
      %{
        kind: "provider",
        label: "Quota",
        summary: "quota exhausted",
        status: "failed"
      }
    ]

    assert {:error, {:provider_failure, [0], :quota_exceeded, ^detail}} =
             Run.run(Classify.tree(),
               run_id: id,
               provider:
                 {ProviderFailureProvider,
                  sink: self(), kind: :quota_exceeded, detail: detail, usage: usage_map, activity: activity}
             )

    assert_received {:agent_called, "classify", %IdempotencyKey{attempt: 0}}
    refute_received {:agent_called, _, _}

    assert types(id) == [:run_started, :agent_failed]

    failed = Enum.find(Journal.fold(id), &(&1.type == :agent_failed))
    assert failed.payload.reason == {:provider_failure, :quota_exceeded, detail}
    assert failed.payload.usage == usage

    assert Enum.map(failed.payload.activity, &activity_fields/1) == [
             %{
               kind: "provider",
               label: "Quota",
               summary: "quota exhausted",
               status: :failed
             }
           ]

    status = Status.of(id)
    assert status.state == :failed
    assert status.failure.reason == {:provider_failure, :quota_exceeded, detail}
    assert status.usage == usage

    assert [agent] = status.agents
    assert agent.status == :failed
    assert agent.usage == usage
    assert agent.activity == failed.payload.activity
  end

  test "invalid output triggers on-thread retry up to the limit, then succeeds" do
    id = run_id()
    outputs = [%{"wrong" => 1}, %{"still" => "wrong"}, %{"label" => "ok"}]

    assert {:ok, ^id} = Run.run(Classify.tree(), run_id: id, provider: provider(outputs))

    # One initial attempt + two retries, all on the same thread.
    assert_received {:agent_called, "classify"}
    assert_received {:agent_called, "classify"}
    assert_received {:agent_called, "classify"}
    refute_received {:agent_called, _}

    # Two rejections are journaled before the committing turn.
    assert types(id) ==
             [
               :run_started,
               :agent_attempt_rejected,
               :agent_attempt_rejected,
               :agent_committed,
               :run_completed
             ]

    status = Status.of(id)
    assert status.state == :completed
    assert length(status.rejected) == 2
    # Every paid attempt (rejections + the commit) is ledgered.
    assert status.usage.total_tokens == 6
  end

  test "exhausting the retry budget fails the node, journaling every attempt and the terminal failure" do
    id = run_id()
    # retries: 2 -> three attempts, all invalid (missing the required "label").
    outputs = [%{"a" => 1}, %{"b" => 2}, %{"c" => 3}]

    assert {:error, {:malformed_output, [0], reason}} =
             Run.run(Classify.tree(), run_id: id, provider: provider(outputs))

    assert reason == {:missing_required, "label"}

    # The provider was called exactly three times, then no more.
    for _ <- 1..3, do: assert_received({:agent_called, "classify"})
    refute_received {:agent_called, _}

    # Three rejections, a terminal failure, and NO run_completed.
    assert types(id) ==
             [
               :run_started,
               :agent_attempt_rejected,
               :agent_attempt_rejected,
               :agent_attempt_rejected,
               :agent_failed
             ]

    failed = Enum.find(Journal.fold(id), &(&1.type == :agent_failed))
    assert failed.payload.attempts == 3
    assert failed.payload.reason == {:missing_required, "label"}

    # The read model is a pure fold: the run reads as failed with the reason.
    status = Status.of(id)
    assert status.state == :failed
    assert status.failure.attempts == 3
    assert status.failure.address == [0]
    assert length(status.rejected) == 3
  end

  test "retry decisions and terminal failure are reconstructable by folding alone" do
    id = run_id()
    {:error, _} = Run.run(Classify.tree(), run_id: id, provider: provider([%{}, %{}, %{}]))

    # The fold over the raw journal equals the live read model — no process state.
    assert Status.fold(Journal.fold(id), id) == Status.of(id)
    assert Status.of(id).state == :failed
  end

  test "resume of a fail-closed terminal run stays failed and never re-runs the provider" do
    id = run_id()

    # Drive the run to its fail-closed terminal state (three rejections, then a
    # terminal agent_failed — no run_completed).
    assert {:error, {:malformed_output, [0], _}} =
             Run.run(Classify.tree(), run_id: id, provider: provider([%{}, %{}, %{}]))

    assert types(id) ==
             [
               :run_started,
               :agent_attempt_rejected,
               :agent_attempt_rejected,
               :agent_attempt_rejected,
               :agent_failed
             ]

    assert Status.of(id).state == :failed

    # Drain the first run's three provider pings so the post-resume refute below is
    # about the resume alone.
    for _ <- 1..3, do: assert_received({:agent_called, "classify"})
    refute_received {:agent_called, _}

    # Re-invoke the same run_id (the exact double-invocation the resume contract
    # relies on). The journal already folds to :failed, so the run is reused
    # verbatim: the provider must never run and no fresh run_started is appended.
    assert {:error, {:malformed_output, [0], {:missing_required, "label"}}} =
             Run.run(Classify.tree(), run_id: id, provider: {ExplodingProvider, []})

    refute_received {:agent_called, _}

    # The pure fold still yields the terminal :failed state — the read model is not
    # un-terminated by the re-invocation.
    assert types(id) ==
             [
               :run_started,
               :agent_attempt_rejected,
               :agent_attempt_rejected,
               :agent_attempt_rejected,
               :agent_failed
             ]

    assert Status.of(id).state == :failed
    assert Status.of(id).failure.attempts == 3
  end

  @tag :capture_log
  test "a mid-retry crash makes the in-flight paid attempt outcome unknown and never redelivers it" do
    id = run_id()

    # First run: two attempts reject (paid + journaled), then the provider faults
    # on the third call, crashing the live writer before it commits attempt 2.
    {:ok, script1} = FlakyProvider.start([%{"a" => 1}, %{"b" => 2}])

    assert {:error, {:run_crashed, _}} =
             Run.run(Classify.tree(),
               run_id: id,
               provider: {FlakyProvider, sink: self(), script: script1}
             )

    # The provider was called three times (two rejects + the faulting call).
    for _ <- 1..3, do: assert_received({:agent_called, "classify"})
    refute_received {:agent_called, _}

    # The two settled rejections remain durable. The third paid call has a start
    # marker but no settlement, so the writer records the ambiguity and fails.
    assert types(id) == [
             :run_started,
             :agent_attempt_rejected,
             :agent_attempt_rejected,
             :run_failed
           ]

    attempt = %{address: [0], iteration: 0, attempt: 2}

    assert %{
             state: :failed,
             failure: %{
               reason: {:outcome_unknown, %IdempotencyKey{run_id: ^id, node_path: [0], iteration: 0, attempt: 2}}
             }
           } = Status.of(id)

    # Reusing the run returns the journaled terminal result and never risks
    # charging the unknown provider attempt a second time.
    assert {:error, {:outcome_unknown, ^attempt}} =
             Run.run(Classify.tree(), run_id: id, provider: {ExplodingProvider, []})

    refute_received {:agent_called, _}
    assert length(Status.of(id).rejected) == 2
  end

  test "distinct retry attempts carry distinct idempotency keys against a deduping backend" do
    id = run_id()

    # A deduping backend keyed by the request idempotency key: attempt 0 is served
    # an invalid output, attempt 1 a valid one. Only *distinct* per-attempt keys let
    # the retry reach the second scripted output; a single shared key would replay
    # attempt 0's rejected output for every retry and the node could never succeed.
    {:ok, store} = DedupingProvider.start([%{"wrong" => 1}, %{"label" => "ok"}])

    assert {:ok, ^id} =
             Run.run(Classify.tree(),
               run_id: id,
               provider: {DedupingProvider, store: store, sink: self()}
             )

    # Exactly two paid calls: the rejected attempt 0 and the committing attempt 1.
    assert_received {:agent_called, "classify"}
    assert_received {:agent_called, "classify"}
    refute_received {:agent_called, _}

    # Each retry has its own key, so neither attempt is deduped onto the other.
    k0 = %IdempotencyKey{run_id: id, node_path: [0], iteration: 0, attempt: 0}
    k1 = %IdempotencyKey{run_id: id, node_path: [0], iteration: 0, attempt: 1}
    assert DedupingProvider.charges(store, k0) == 1
    assert DedupingProvider.charges(store, k1) == 1

    committed = Enum.find(Journal.fold(id), &(&1.type == :agent_committed))
    assert committed.payload.result == %{"label" => "ok"}
    # The committing turn is the second attempt, keyed accordingly.
    assert committed.payload.idempotency_key.attempt == 1

    assert types(id) == [:run_started, :agent_attempt_rejected, :agent_committed, :run_completed]
    assert Status.of(id).state == :completed
  end

  test "resume replays a committed schema-agent effect instead of re-running the paid turn" do
    id = run_id()

    assert {:ok, ^id} =
             Run.run(Classify.tree(), run_id: id, provider: provider([%{"label" => "ok"}]))

    assert_received {:agent_called, "classify"}

    # Resume the same run_id with a provider that explodes if ever called: the
    # committed turn must be replayed from the journal, so it must not run.
    assert {:ok, ^id} = Run.run(Classify.tree(), run_id: id, provider: {ExplodingProvider, []})
    refute_received {:agent_called, _}

    committed = Enum.filter(Journal.fold(id), &(&1.type == :agent_committed))
    assert [%{payload: %{result: %{"label" => "ok"}}}] = committed
  end

  test "a schema-backed injected agent journals a byte-identical rendered prompt across rejection and commit" do
    id = run_id()
    outputs = ["READY", %{"wrong" => 1}, %{"label" => "ok"}]

    assert {:ok, ^id} = Run.run(InjectedClassify.tree(), run_id: id, provider: provider(outputs))

    assert_received {:agent_called, "draft"}
    assert_received {:agent_called, "classify: READY"}
    assert_received {:agent_called, "classify: READY"}
    refute_received {:agent_called, _}

    events = Journal.fold(id)

    rejected =
      Enum.find(events, &(&1.type == :agent_attempt_rejected and &1.payload.address == [1]))

    committed =
      Enum.find(events, &(&1.type == :agent_committed and &1.payload.address == [1]))

    assert rejected.payload.prompt == "classify: READY"
    assert committed.payload.prompt == "classify: READY"
    assert rejected.payload.prompt == committed.payload.prompt
  end
end
