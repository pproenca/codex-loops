defmodule Workflow.DataflowRunTest do
  @moduledoc """
  End-to-end run coverage for slice #15's dataflow core. These assertions pin
  rendered terminal values, the absence of extra journal events, and the existing
  `run_completed` fold/status behavior.
  """
  use ExUnit.Case, async: true

  alias Workflow.{BoundValue, Event, Journal, RenderText, Run, Status}
  alias Workflow.Template.Hole
  alias Workflow.Test.{EchoProvider, RefineProvider, ScriptedProvider}

  defmodule BinaryEmit do
    use Workflow

    workflow "binary-emit" do
      let(:draft = agent("Write a draft."))
      emit(~P"Final draft: <%= @draft %>")
    end
  end

  defmodule SynthesizedEmit do
    use Workflow

    workflow "synthesized-emit" do
      let(:summary = synthesize(["plan A", "plan B"], "Merge the plans."))
      emit(~P"Summary: <%= @summary %>")
    end
  end

  defmodule MapEmit do
    use Workflow

    workflow "map-emit" do
      let(:draft = agent("Write a draft."))
      emit(~P"Final draft: <%= @draft %>")
    end
  end

  defmodule InjectedAgent do
    use Workflow

    workflow "injected-agent" do
      let(:draft = agent("Write a draft."))
      agent(~P"Improve this draft: <%= @draft %>")
      return(:ok)
    end
  end

  defmodule FormatterEmit do
    use Workflow

    workflow "formatter-emit" do
      let(:draft = agent("Draft."))
      let(:review = agent("Review."))

      emit(~P|ID: <%= path(@review, "/items/0/id") %>
Count: <%= count(@review, "/items") %>
Flat: <%= flatten(@review, "/groups") %>
Findings:
<%= numbered_findings(@review, "/items") %>
Short: <%= truncate(@draft, 5) %>|)
    end
  end

  defmodule RefineResultEmit do
    use Workflow

    workflow "refine-result-emit" do
      let(
        :final =
          refine(agent("Draft."),
            reviewers: [
              reviewer(:spec, "Check the spec."),
              reviewer(:runtime, "Check the runtime.")
            ],
            revise_with: agent("Fix."),
            until: :unanimous,
            max_rounds: 1,
            on_non_convergence: :accept_current
          )
      )

      emit_result(:final)
    end
  end

  defp run_id, do: "run_#{System.unique_integer([:positive])}"
  defp types(id), do: Journal.fold(id) |> Enum.map(& &1.type)

  test "emit renders a binary-valued binding into run_completed.value exactly" do
    id = run_id()
    {:ok, script} = ScriptedProvider.start(["READY"])

    assert {:ok, ^id} =
             Run.run(BinaryEmit,
               run_id: id,
               provider: {ScriptedProvider, script: script, sink: self()}
             )

    assert_received {:agent_called, "Write a draft."}
    refute_received {:agent_called, _}

    assert types(id) == [:run_started, :agent_committed, :run_completed]

    assert %Event{payload: %{value: "Final draft: READY"}} =
             Enum.find(Journal.fold(id), &(&1.type == :run_completed))

    assert Status.of(id).state == :completed
    assert Status.of(id).result == "Final draft: READY"
  end

  test "let-bound synthesize reuses the existing render/prompt seams and emits the terminal value" do
    id = run_id()
    {:ok, script} = ScriptedProvider.start(["Merged summary"])

    assert {:ok, ^id} =
             Run.run(SynthesizedEmit,
               run_id: id,
               provider: {ScriptedProvider, script: script, sink: self()}
             )

    assert_received {:agent_called, "Merge the plans.\n\nInputs: [\"plan A\", \"plan B\"]"}

    assert %Event{payload: %{value: "Summary: Merged summary"}} =
             Enum.find(Journal.fold(id), &(&1.type == :run_completed))
  end

  test "map-bearing terminal render is asserted structurally, not byte-for-byte" do
    id = run_id()

    assert {:ok, ^id} = Run.run(MapEmit, run_id: id, provider: {EchoProvider, sink: self()})

    assert %Event{payload: %{value: rendered}} =
             Enum.find(Journal.fold(id), &(&1.type == :run_completed))

    assert String.starts_with?(rendered, "Final draft: %{")
    assert rendered =~ ~s|"echo" => "Write a draft."|
    assert Status.of(id).result == rendered
  end

  test "a top-level agent template prompt renders journal-bound values before provider call and commit" do
    id = run_id()
    {:ok, script} = ScriptedProvider.start(["READY", "done"])

    assert {:ok, ^id} =
             Run.run(InjectedAgent,
               run_id: id,
               provider: {ScriptedProvider, script: script, sink: self()}
             )

    assert_received {:agent_called, "Write a draft."}
    assert_received {:agent_called, "Improve this draft: READY"}
    refute_received {:agent_called, _}

    committed =
      Journal.fold(id)
      |> Enum.filter(&(&1.type == :agent_committed))

    assert [
             %Event{payload: %{address: [0], prompt: "Write a draft.", result: "READY"}},
             %Event{
               payload: %{address: [1], prompt: "Improve this draft: READY", result: "done"}
             }
           ] = committed
  end

  test "adopted template formatters render from journal-bound structured values" do
    id = run_id()

    review = %{
      :items => [
        %{id: "F1", issue: "Bug", fix: "Patch"},
        %{"id" => "F2", "issue" => "Risk", "fix" => "Guard"}
      ],
      "groups" => [["a"], ["b", "c"]]
    }

    {:ok, script} = ScriptedProvider.start(["cafétéria", review])

    assert {:ok, ^id} =
             Run.run(FormatterEmit,
               run_id: id,
               provider: {ScriptedProvider, script: script, sink: self()}
             )

    assert_received {:agent_called, "Draft."}
    assert_received {:agent_called, "Review."}

    assert %Event{payload: %{value: rendered}} =
             Enum.find(Journal.fold(id), &(&1.type == :run_completed))

    assert rendered ==
             "ID: F1\n" <>
               "Count: 2\n" <>
               "Flat: [\"a\", \"b\", \"c\"]\n" <>
               "Findings:\n" <>
               "1. [F1] Bug\n" <>
               "   Fix: Patch\n" <>
               "2. [F2] Risk\n" <>
               "   Fix: Guard\n" <>
               "Short: café"

    assert Status.of(id).result == rendered
  end

  test "emit_result writes a structured public refine result into run_completed.value" do
    id = run_id()

    finding = %{
      "id" => "still-bad",
      "blocking" => true,
      "issue" => "Still bad.",
      "fix" => "Fix it."
    }

    assert {:ok, ^id} =
             Run.run(RefineResultEmit,
               run_id: id,
               provider:
                 {RefineProvider,
                  artifact: "draft-v1",
                  reviews: [
                    [approved: false, findings: [finding]],
                    [approved: true, findings: []]
                  ],
                  sink: self()}
             )

    assert %Event{payload: %{value: result}} =
             Enum.find(Journal.fold(id), &(&1.type == :run_completed))

    assert result["artifact"] == "draft-v1"
    assert result["converged"] == false
    assert result["rounds"] == 1
    assert result["finalRound"] == 0

    assert result["openFindings"] == [
             %{
               "reviewer" => "spec",
               "reviewerIndex" => 0,
               "id" => "still-bad",
               "issue" => "Still bad.",
               "fix" => "Fix it."
             }
           ]

    assert result["finalOpenDefects"] == result["openFindings"]
    assert result["roleFailures"] == []
    assert result["failedReviewers"] == []
    assert result["coldRead"] == nil
    assert result["reportSnippets"] == []

    assert result["reviewerDecisions"] == [
             %{
               "reviewer" => "spec",
               "reviewerIndex" => 0,
               "approved" => false,
               "clear" => false,
               "adapter" => "findings_v1",
               "status" => "completed"
             },
             %{
               "reviewer" => "runtime",
               "reviewerIndex" => 1,
               "approved" => true,
               "clear" => true,
               "adapter" => "findings_v1",
               "status" => "completed"
             }
           ]

    assert %{"journal" => raw_refs} = result["rawRefs"]
    assert Enum.map(raw_refs, & &1["type"]) == ["refine_round_decision", "refine_completed"]
    assert Enum.all?(raw_refs, &(&1["runId"] == id and &1["address"] == [0]))

    refute contains_atom?(result)
    assert Jason.encode!(result)
    assert Status.of(id).result == result
    assert BoundValue.of(id, {:refine, [0]}) == {:ok, "draft-v1"}
  end

  test "JSON pointer list tokens are unsigned decimal indices" do
    assert {:ok, "second"} =
             RenderText.fold([], [
               {:formatter, %Hole{op: :path, assign: "xs", args: %{pointer: "/1"}},
                {:literal, ["first", "second"]}}
             ])

    assert {:ok, "nil"} =
             RenderText.fold([], [
               {:formatter, %Hole{op: :path, assign: "xs", args: %{pointer: "/+1"}},
                {:literal, ["first", "second"]}}
             ])

    assert {:ok, "nil"} =
             RenderText.fold([], [
               {:formatter, %Hole{op: :path, assign: "xs", args: %{pointer: "/-0"}},
                {:literal, ["first", "second"]}}
             ])
  end

  test "numbered_findings atom fallback preserves falsey field values" do
    assert {:ok, "1. [false] nil\n   Fix: 0"} =
             RenderText.fold([], [
               {:formatter,
                %Hole{op: :numbered_findings, assign: "findings", args: %{pointer: ""}},
                {:literal, [%{id: false, issue: nil, fix: 0}]}}
             ])
  end

  defp contains_atom?(nil), do: false
  defp contains_atom?(value) when is_boolean(value), do: false
  defp contains_atom?(value) when is_atom(value), do: true

  defp contains_atom?(value) when is_map(value) do
    Enum.any?(value, fn {key, nested} -> is_atom(key) or contains_atom?(nested) end)
  end

  defp contains_atom?(value) when is_list(value), do: Enum.any?(value, &contains_atom?/1)
  defp contains_atom?(_value), do: false
end
