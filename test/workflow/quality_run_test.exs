defmodule Workflow.QualityRunTest do
  @moduledoc """
  Run semantics for the quality combinators, driven through the interpreter over
  inert trees with deterministic, call-counting mock providers. Every assertion is
  on external behaviour: provider call counts, the committed journal (its panel
  brackets and stable per-vote/per-score node addresses), and the folded read model
  — never process internals.

  Covers the slice-#8 acceptance criteria: adversarial-verify survives only when the
  threshold confirms; judge-panel scores N candidates, picks a winner, and
  synthesizes; and `fan_out width: budget_slices(per: N)` spawns `floor(remaining/N)`
  branches deterministically.
  """
  use ExUnit.Case, async: true

  alias Workflow.Catalog.AdversarialVerify
  alias Workflow.Catalog.JudgePanel
  alias Workflow.Journal
  alias Workflow.Run
  alias Workflow.Status
  alias Workflow.Test.EchoProvider
  alias Workflow.Test.ExplodingProvider
  alias Workflow.Test.PanelProvider
  alias Workflow.Test.ScriptedProvider
  alias Workflow.Test.VerdictProvider

  defp run_id, do: "run_#{System.unique_integer([:positive])}"
  defp types(id), do: id |> Journal.fold() |> Enum.map(& &1.type)
  defp event(id, type), do: id |> Journal.fold() |> Enum.find(&(&1.type == type))

  defp committed_addresses(id) do
    id
    |> Journal.fold()
    |> Enum.filter(&(&1.type == :agent_committed))
    |> Enum.map(& &1.payload.address)
  end

  # --- verify: a finding survives only when the threshold of voters confirms ---

  defmodule Voters do
    @moduledoc false
    use Workflow

    workflow "voters" do
      verify("the finding", voters: 3, threshold: :majority)
      return(:ok)
    end
  end

  test "a finding survives when a majority of voters confirm" do
    id = run_id()

    assert {:ok, ^id} =
             Run.run(Voters,
               run_id: id,
               provider: {VerdictProvider, verdicts: [true, true, false], sink: self()}
             )

    # Three votes were cast, once each, at their own stable branch addresses.
    for _ <- 1..3, do: assert_received({:agent_called, _})
    refute_received {:agent_called, _}
    assert committed_addresses(id) == [[0, 0], [0, 1], [0, 2]]

    # The concurrent panel is bracketed and then settled by a pure fold of verdicts.
    assert types(id) ==
             [
               :run_started,
               :verify_started,
               :agent_committed,
               :agent_committed,
               :agent_committed,
               :verify_settled,
               :run_completed
             ]

    vote_prompts =
      id
      |> Journal.fold()
      |> Enum.filter(&(&1.type == :agent_committed))
      |> Enum.map(& &1.payload.prompt)

    assert vote_prompts == [
             "Confirm or refute this finding, answering with a boolean verdict: the finding",
             "Confirm or refute this finding, answering with a boolean verdict: the finding",
             "Confirm or refute this finding, answering with a boolean verdict: the finding"
           ]

    settled = event(id, :verify_settled).payload

    assert settled == %{
             address: [0],
             confirmations: 2,
             total: 3,
             threshold: :majority,
             survived: true
           }

    status = Status.of(id)
    assert status.state == :completed

    assert status.verifications == [
             %{address: [0], confirmations: 2, total: 3, threshold: :majority, survived: true}
           ]
  end

  test "a finding does not survive when the threshold is not met" do
    id = run_id()

    assert {:ok, ^id} =
             Run.run(Voters,
               run_id: id,
               provider: {VerdictProvider, verdicts: [true, false, false], sink: self()}
             )

    settled = event(id, :verify_settled).payload
    assert settled.confirmations == 1
    assert settled.survived == false

    assert Status.of(id).verifications == [
             %{address: [0], confirmations: 1, total: 3, threshold: :majority, survived: false}
           ]
  end

  test "adversarial-verify catalog: perspective-diverse lenses settle survival by a folded majority" do
    id = run_id()

    # Correctness and repro confirm, security refutes: 2/3 -> majority holds.
    assert {:ok, ^id} =
             Run.run(AdversarialVerify,
               run_id: id,
               provider: {VerdictProvider, verdicts: [true, false, true], sink: self()}
             )

    for _ <- 1..3, do: assert_received({:agent_called, _})

    settled = event(id, :verify_settled).payload

    assert settled == %{
             address: [0],
             confirmations: 2,
             total: 3,
             threshold: :majority,
             survived: true
           }

    assert Status.of(id).state == :completed
  end

  test "a completed verify resumes by replaying journaled votes, never re-invoking" do
    id = run_id()

    assert {:ok, ^id} =
             Run.run(Voters,
               run_id: id,
               provider: {VerdictProvider, verdicts: [true, true, true], sink: self()}
             )

    for _ <- 1..3, do: assert_received({:agent_called, _})
    before = id |> Journal.fold() |> length()

    # Re-invoking folds to :completed: votes replay from the journal, so the provider
    # never runs again and no new events are appended.
    assert {:ok, ^id} = Run.run(Voters, run_id: id, provider: {ExplodingProvider, []})
    refute_received {:agent_called, _}
    assert id |> Journal.fold() |> length() == before
    assert Status.of(id).verifications |> hd() |> Map.fetch!(:survived) == true
  end

  defmodule StrictVote do
    @moduledoc false
    use Workflow

    # A voter whose output must carry a boolean verdict; a provider that returns
    # something else fails the vote closed, and the failed vote fails the panel.
    workflow "strict-vote" do
      verify("the finding", voters: 2, threshold: :unanimous)
      return(:ok)
    end
  end

  test "a malformed vote fails the panel (fail-closed, no retries)" do
    id = run_id()

    # EchoProvider returns %{"echo" => prompt} — no "verdict" — so each vote fails
    # its schema with retries: 0.
    assert {:error, {:malformed_output, address, _reason}} =
             Run.run(StrictVote, run_id: id, provider: {EchoProvider, sink: self()})

    assert address in [[0, 0], [0, 1]]
    event_types = types(id)

    assert :agent_failed in event_types
    refute :verify_settled in event_types
    refute :run_completed in event_types
    assert Status.of(id).state == :failed
  end

  # --- refine: inline producer converges when every reviewer clears round 0 ---

  defmodule InlineRefine do
    @moduledoc false
    use Workflow

    workflow "inline-refine" do
      refine(agent("Draft artifact."),
        reviewers: [
          reviewer(:spec, "Spec reviewer."),
          reviewer(:runtime, "Runtime reviewer.")
        ],
        revise_with: agent("Revise artifact."),
        until: :unanimous,
        max_rounds: 3
      )

      return(:ok)
    end
  end

  test "refine runs inline producer and reviewers, then commits a converged round-0 artifact" do
    id = run_id()

    {:ok, script} =
      ScriptedProvider.start([
        %{"artifact" => "draft v1"},
        %{"approved" => true, "findings" => []},
        %{"approved" => true, "findings" => []}
      ])

    assert {:ok, ^id} =
             Run.run(InlineRefine,
               run_id: id,
               provider: {ScriptedProvider, script: script, sink: self()}
             )

    assert_received {:agent_called, "Draft artifact."}
    assert_received {:agent_called, reviewer_prompt_1}
    assert_received {:agent_called, reviewer_prompt_2}
    refute_received {:agent_called, "Revise artifact."}
    refute_received {:agent_called, _}

    reviewer_prompts = [reviewer_prompt_1, reviewer_prompt_2]
    spec_prompt = Enum.find(reviewer_prompts, &String.contains?(&1, "Spec reviewer."))
    runtime_prompt = Enum.find(reviewer_prompts, &String.contains?(&1, "Runtime reviewer."))

    assert spec_prompt =~ "Spec reviewer."
    assert spec_prompt =~ "--- CODEX LOOPS REFINE REVIEW INPUT ---"
    assert spec_prompt =~ "round: 0"
    assert spec_prompt =~ "artifact:\ndraft v1"
    assert runtime_prompt =~ "Runtime reviewer."
    assert runtime_prompt =~ "artifact:\ndraft v1"

    assert types(id) ==
             [
               :run_started,
               :refine_started,
               :agent_committed,
               :refine_round_started,
               :agent_committed,
               :agent_committed,
               :refine_round_decision,
               :refine_completed,
               :run_completed
             ]

    committed =
      id
      |> Journal.fold()
      |> Enum.filter(&(&1.type == :agent_committed))

    assert [
             %{payload: %{address: [0, 0], iteration: 0, result: "draft v1"}},
             %{
               payload: %{
                 address: [0, 1, 0],
                 iteration: 0,
                 result: %{"approved" => true, "findings" => []}
               }
             },
             %{
               payload: %{
                 address: [0, 1, 1],
                 iteration: 0,
                 result: %{"approved" => true, "findings" => []}
               }
             }
           ] = committed

    decision = event(id, :refine_round_decision).payload
    assert decision.address == [0]
    assert decision.round == 0
    assert decision.consensus == true
    assert decision.approval_count == 2
    assert decision.total == 2
    assert decision.artifact == "draft v1"
    assert decision.open_findings == []

    assert decision.reviewer_decisions == [
             %{
               reviewer: :spec,
               reviewer_index: 0,
               approved: true,
               clear: true,
               adapter: :findings_v1,
               status: :completed
             },
             %{
               reviewer: :runtime,
               reviewer_index: 1,
               approved: true,
               clear: true,
               adapter: :findings_v1,
               status: :completed
             }
           ]

    assert decision.report_snippets == []

    completed = event(id, :refine_completed).payload
    assert completed.converged == true
    assert completed.final_round == 0
    assert completed.rounds == 1
    assert completed.artifact == "draft v1"
    assert completed.open_findings == []

    assert Status.of(id).state == :completed
  end

  # --- judge: N candidates scored, winner picked, synthesized ---

  test "judge-panel catalog scores every candidate, picks the max, and synthesizes" do
    id = run_id()

    # Totals per candidate = score x 2 criteria: A=2, B=10, C=6 -> winner "plan B".
    assert {:ok, ^id} =
             Run.run(JudgePanel,
               run_id: id,
               provider: {PanelProvider, scores: [1, 5, 3], sink: self()}
             )

    # Six scoring turns (3 candidates x 2 criteria) then one synthesis turn.
    for _ <- 1..7, do: assert_received({:agent_called, _})
    refute_received {:agent_called, _}

    # Each score lands at its own [judge, candidate, criterion] address; the synthesis
    # turn lands at the synthesize node's own address.
    assert committed_addresses(id) ==
             [[0, 0, 0], [0, 0, 1], [0, 1, 0], [0, 1, 1], [0, 2, 0], [0, 2, 1], [1]]

    assert :judge_started in types(id)
    assert :judge_settled in types(id)

    scorer_prompts =
      id
      |> Journal.fold()
      |> Enum.filter(&(&1.type == :agent_committed and &1.payload.address != [1]))
      |> Enum.map(& &1.payload.prompt)

    assert scorer_prompts == [
             "Score this candidate on feasibility, answering with a numeric score: plan A",
             "Score this candidate on impact, answering with a numeric score: plan A",
             "Score this candidate on feasibility, answering with a numeric score: plan B",
             "Score this candidate on impact, answering with a numeric score: plan B",
             "Score this candidate on feasibility, answering with a numeric score: plan C",
             "Score this candidate on impact, answering with a numeric score: plan C"
           ]

    settled = event(id, :judge_settled).payload
    assert settled.pick == :max_score
    assert settled.winner == "plan B"
    assert settled.scores == %{"plan A" => 2, "plan B" => 10, "plan C" => 6}

    status = Status.of(id)
    assert status.state == :completed
    assert status.result == :done

    synthesis =
      id
      |> Journal.fold()
      |> Enum.find(&(&1.type == :agent_committed and &1.payload.address == [1]))

    assert synthesis.payload.prompt ==
             ~s(Write up the winning plan.\n\nInputs: ["plan A", "plan B", "plan C"])

    assert status.judgments == [
             %{
               address: [0],
               scores: %{"plan A" => 2, "plan B" => 10, "plan C" => 6},
               pick: :max_score,
               winner: "plan B"
             }
           ]
  end

  # --- fan_out: floor(remaining / per) branches, deterministically ---

  defmodule Widen do
    @moduledoc false
    use Workflow

    workflow "widen" do
      fan_out width: budget_slices(per: 10) do
        agent("work")
      end

      return(:ok)
    end
  end

  test "fan_out spawns floor(remaining / per) branches and journals the decided width" do
    id = run_id()

    # remaining 40, per 10 -> floor(40/10) = 4 branches.
    assert {:ok, ^id} =
             Run.run(Widen, run_id: id, budget: 40, provider: {EchoProvider, sink: self()})

    for _ <- 1..4, do: assert_received({:agent_called, "work"})
    refute_received {:agent_called, _}

    started = event(id, :fan_out_started).payload
    assert started == %{address: [0], per: 10, width: 4}
    assert :fan_out_completed in types(id)

    # Each branch runs the body at its own [fan_out, branch, stage] address.
    assert committed_addresses(id) == [[0, 0, 0], [0, 1, 0], [0, 2, 0], [0, 3, 0]]
    assert Status.of(id).state == :completed
  end

  test "fan_out width floors deterministically for a non-divisible remaining" do
    id = run_id()

    # remaining 25, per 10 -> floor(25/10) = 2 branches.
    assert {:ok, ^id} =
             Run.run(Widen, run_id: id, budget: 25, provider: {EchoProvider, sink: self()})

    for _ <- 1..2, do: assert_received({:agent_called, "work"})
    refute_received {:agent_called, _}
    assert event(id, :fan_out_started).payload.width == 2
    assert committed_addresses(id) == [[0, 0, 0], [0, 1, 0]]
  end

  test "fan_out with remaining below per spawns zero branches" do
    id = run_id()

    # remaining 5, per 10 -> floor(5/10) = 0: the region is bracketed but empty.
    assert {:ok, ^id} =
             Run.run(Widen, run_id: id, budget: 5, provider: {EchoProvider, sink: self()})

    refute_received {:agent_called, _}
    assert event(id, :fan_out_started).payload.width == 0
    assert :fan_out_completed in types(id)
    assert committed_addresses(id) == []
    assert Status.of(id).state == :completed
  end

  @tag :capture_log
  test "fan_out on an unbounded run fails cleanly (budget_slices needs a budget)" do
    id = run_id()

    assert {:error, {:run_crashed, _}} =
             Run.run(Widen, run_id: id, provider: {EchoProvider, sink: self()})
  end
end
