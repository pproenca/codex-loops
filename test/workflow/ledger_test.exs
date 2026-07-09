defmodule Workflow.LedgerTest do
  @moduledoc """
  Budget-ledger semantics. The ledger is a pure fold over the journal, so the unit
  tests drive `Ledger.fold/1` directly over journal event streams (built from the
  same `Event` constructors the writer commits), and the integration tests fold a
  real run's committed journal through a call-counting mock provider. Every
  assertion is on derived budget state — `spent`, `total`, `remaining` — never on
  process state.
  """
  use ExUnit.Case, async: true

  alias Workflow.Event
  alias Workflow.Journal
  alias Workflow.Ledger
  alias Workflow.Node.Agent
  alias Workflow.Provider.Usage
  alias Workflow.Run
  alias Workflow.Test.EchoProvider
  alias Workflow.Test.ProviderFailureProvider
  alias Workflow.Test.ScriptedProvider

  defmodule Demo do
    @moduledoc false
    use Workflow

    workflow "demo" do
      agent("say hello")
      return(:ok)
    end
  end

  # A schema-backed agent: three attempts (retries: 2), used to produce a run whose
  # journal holds several paid usage events (rejections + a commit).
  defmodule Classify do
    @moduledoc false
    use Workflow

    workflow "classify" do
      agent("classify", schema: %{"type" => "object", "required" => ["label"]}, retries: 2)
      return(:ok)
    end
  end

  defp run_id, do: "run_#{System.unique_integer([:positive])}"
  defp echo, do: {EchoProvider, sink: self()}

  defp scripted(outputs) do
    {:ok, script} = ScriptedProvider.start(outputs)
    {ScriptedProvider, sink: self(), script: script}
  end

  # Build the journal events a turn commits, using the real Event constructors.
  defp started(budget), do: Event.run_started(%Workflow.Tree{nodes: []}, budget)

  defp committed(usage) do
    Event.agent_committed(%Agent{address: [0], prompt: "p"}, 0, :key, %{}, usage(usage))
  end

  defp rejected(usage) do
    Event.agent_attempt_rejected(%Agent{address: [0], prompt: "p"}, 0, 0, %{}, :bad, usage(usage))
  end

  defp failed(total_tokens) do
    Event.agent_failed(
      %Agent{address: [0], prompt: "p"},
      0,
      1,
      {:provider_failure, :timeout, %{"message" => "deadline"}},
      usage(total_tokens)
    )
  end

  defp role_failed(total_tokens) do
    Event.refine_role_failed(%{
      address: [0],
      role: :reviewer,
      role_address: [0, 1, 0],
      round: 0,
      reviewer: :spec,
      reviewer_index: 0,
      attempts: 1,
      reason: {:provider_failure, :timeout, %{"message" => "deadline"}},
      detail: %{"message" => "deadline"},
      usage: usage(total_tokens),
      activity: []
    })
  end

  defp usage(total), do: %Usage{input_tokens: 0, output_tokens: total, total_tokens: total}

  describe "pure fold (Ledger.fold/1)" do
    test "no target: spent accumulates, total stays nil, remaining is :infinity" do
      ledger = Ledger.fold([started(nil), committed(8), committed(5)])

      assert ledger.total == nil
      assert ledger.spent == 13
      assert Ledger.remaining(ledger) == :infinity
    end

    test "target set: remaining is total minus the paid spend" do
      ledger = Ledger.fold([started(100), committed(8)])

      assert ledger.total == 100
      assert ledger.spent == 8
      assert Ledger.remaining(ledger) == 92
    end

    test "rejected fail-closed attempts are paid and count against the budget" do
      # Two rejections + one commit, each 2 tokens, against a target of 10.
      ledger = Ledger.fold([started(10), rejected(2), rejected(2), committed(2)])

      assert ledger.spent == 6
      assert Ledger.remaining(ledger) == 4
    end

    test "expected provider failure usage counts against the budget" do
      ledger = Ledger.fold([started(10), failed(3)])

      assert ledger.spent == 3
      assert Ledger.remaining(ledger) == 7
    end

    test "refine role failure usage counts against the budget" do
      ledger = Ledger.fold([started(10), role_failed(4)])

      assert ledger.spent == 4
      assert Ledger.remaining(ledger) == 6
    end

    test "schema-exhaustion failures with nil usage do not move the budget" do
      ledger =
        Ledger.fold([
          started(10),
          Event.agent_failed(
            %Agent{address: [0], prompt: "p"},
            0,
            1,
            {:missing_required, "label"}
          )
        ])

      assert ledger.spent == 0
      assert Ledger.remaining(ledger) == 10
    end

    test "an empty journal folds to the unbounded zero-spend default" do
      ledger = Ledger.fold([])

      assert ledger == %Ledger{total: nil, spent: 0}
      assert Ledger.remaining(ledger) == :infinity
    end

    test "remaining is monotonically non-increasing across every journal prefix" do
      events = [started(10), rejected(2), rejected(2), committed(2), Event.run_completed(:ok)]

      remainings =
        for n <- 0..length(events) do
          events |> Enum.take(n) |> Ledger.fold() |> Ledger.remaining()
        end

      # Each step is <= the one before it (:infinity sorts above every integer, so a
      # plain >= comparison is total over the mixed sequence).
      assert remainings == [:infinity, 10, 8, 6, 4, 4]
      assert remainings |> Enum.chunk_every(2, 1, :discard) |> Enum.all?(fn [a, b] -> a >= b end)
    end

    test ":infinity answers `remaining > 0` for an unbounded run, driving termination checks" do
      unbounded = Ledger.remaining(Ledger.fold([started(nil), committed(999)]))
      bounded = Ledger.remaining(Ledger.fold([started(5), committed(2)]))

      assert unbounded > 0
      assert bounded > 0
      assert Ledger.remaining(Ledger.fold([started(5), committed(5)])) <= 0
    end
  end

  describe "over a real run (Ledger.of/1)" do
    test "a target run exposes remaining after the agent turn, folded from the journal" do
      id = run_id()
      # EchoProvider bills 8 total tokens for the single turn.
      assert {:ok, ^id} = Run.run(Demo, run_id: id, provider: echo(), budget: 100)

      ledger = Ledger.of(id)
      assert ledger.total == 100
      assert ledger.spent == 8
      assert Ledger.remaining(ledger) == 92

      # Purity: folding the raw journal by hand yields the identical ledger.
      assert Ledger.fold(Journal.fold(id)) == ledger
    end

    test "an unbounded run (no budget) folds to total nil and :infinity remaining" do
      id = run_id()
      assert {:ok, ^id} = Run.run(Demo, run_id: id, provider: echo())

      ledger = Ledger.of(id)
      assert ledger.total == nil
      assert ledger.spent == 8
      assert Ledger.remaining(ledger) == :infinity
    end

    test "every paid attempt of a fail-closed run is ledgered, then reused on resume" do
      id = run_id()
      # Two invalid outputs (rejected) then a valid one (committed): three paid turns
      # of 2 tokens each = 6 spent, against a target of 50.
      outputs = [%{"wrong" => 1}, %{"still" => "bad"}, %{"label" => "ok"}]
      assert {:ok, ^id} = Run.run(Classify, run_id: id, provider: scripted(outputs), budget: 50)

      ledger = Ledger.of(id)
      assert ledger.spent == 6
      assert Ledger.remaining(ledger) == 44

      # Resume reads the same journal — the target and spend are reconstructed, never
      # re-supplied or double-counted.
      assert {:ok, ^id} =
               Run.run(Classify, run_id: id, provider: {Workflow.Test.ExplodingProvider, []})

      assert Ledger.of(id) == ledger
    end

    test "expected provider failure usage is reconstructed from the journal" do
      id = run_id()

      assert {:error, {:provider_failure, [0], :timeout, %{"message" => "deadline"}}} =
               Run.run(Demo,
                 run_id: id,
                 provider:
                   {ProviderFailureProvider,
                    detail: %{"message" => "deadline"}, usage: %Usage{input_tokens: 2, output_tokens: 1, total_tokens: 3}},
                 budget: 50
               )

      ledger = Ledger.of(id)

      assert ledger.spent == 3
      assert Ledger.remaining(ledger) == 47
    end
  end
end
