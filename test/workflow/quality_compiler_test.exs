defmodule Workflow.QualityCompilerTest do
  @moduledoc """
  The quality combinators (`verify`, `judge`, `synthesize`, `fan_out`) exercised at
  the highest DSL seam — `Workflow.Compiler.compile/3` — directly against
  `quote`d/string-sourced input with no macro expansion. Assertions are on the
  inert, pre-addressed tree the compiler produces and on the located findings it
  returns (or the raises the forbidden-form catalog throws) for malformed input.
  """
  use ExUnit.Case, async: true

  alias Workflow.Compiler
  alias Workflow.Compiler.Finding
  alias Workflow.Node.Agent
  alias Workflow.Node.BudgetSlices
  alias Workflow.Node.GenericFanout
  alias Workflow.Node.Judge
  alias Workflow.Node.Refine
  alias Workflow.Node.Return
  alias Workflow.Node.Synthesize
  alias Workflow.Node.Verify
  alias Workflow.Schema

  defp env, do: %{__ENV__ | file: "workflows/quality.ex", line: 1}
  defp parse(source), do: Compiler.compile("test", Code.string_to_quoted!(source), env())

  describe "verify (bounded voting panel)" do
    test "voters mode expands into N pre-addressed, schema-bound, closure-free votes" do
      {:ok, tree} = parse(~s|verify "finding", voters: 3, threshold: :majority\nreturn(:ok)|)

      assert [
               %Verify{
                 address: [0],
                 subject: "finding",
                 mode: {:voters, 3},
                 threshold: :majority,
                 voters: [
                   %Agent{
                     address: [0, 0],
                     prompt: "Confirm or refute this finding, answering with a boolean verdict: finding",
                     schema: schema,
                     retries: 0
                   },
                   %Agent{address: [0, 1]},
                   %Agent{address: [0, 2]}
                 ]
               },
               %Return{value: :ok}
             ] = tree.nodes

      # Every vote carries the same verdict schema (fail-closed, no retries).
      assert Schema.to_map(schema)["properties"]["verdict"] == %{"type" => "boolean"}
      refute contains_function?(tree)
    end

    test "lenses mode expands into one perspective-framed vote per lens" do
      {:ok, tree} =
        parse(~s|verify "bug", lenses: [:correctness, :security, :repro]\nreturn(:ok)|)

      assert [%Verify{mode: {:lenses, [:correctness, :security, :repro]}, voters: voters}, _] =
               tree.nodes

      assert [
               %Agent{address: [0, 0], prompt: p0},
               %Agent{address: [0, 1], prompt: p1},
               %Agent{address: [0, 2], prompt: p2}
             ] = voters

      # Each vote is framed by its lens perspective; the count is fixed at author time.
      assert p0 ==
               "From the correctness perspective, confirm or refute this finding, answering with a boolean verdict: bug"

      assert p0 =~ "correctness"

      assert p1 ==
               "From the security perspective, confirm or refute this finding, answering with a boolean verdict: bug"

      assert p1 =~ "security"

      assert p2 ==
               "From the repro perspective, confirm or refute this finding, answering with a boolean verdict: bug"

      assert p2 =~ "repro"
      refute contains_function?(tree)
    end

    test "threshold defaults to :majority when omitted" do
      {:ok, tree} = parse(~s|verify "x", voters: 5\nreturn(:ok)|)
      assert [%Verify{threshold: :majority}, _] = tree.nodes
    end

    test "an integer threshold within the panel is accepted" do
      {:ok, tree} = parse(~s|verify "x", voters: 3, threshold: 2\nreturn(:ok)|)
      assert [%Verify{threshold: 2}, _] = tree.nodes
    end

    test "an integer threshold larger than the panel is a located finding" do
      assert {:error, %Finding{line: 1} = f} =
               parse(~s|verify "x", voters: 3, threshold: 4\nreturn(:ok)|)

      assert f.message =~ "out of range"
    end

    test "requiring both voters and lenses is a located finding" do
      assert {:error, %Finding{} = f} =
               parse(~s|verify "x", voters: 3, lenses: [:a]\nreturn(:ok)|)

      assert f.message =~ "not both"
    end

    test "neither voters nor lenses is a located finding" do
      assert {:error, %Finding{} = f} = parse(~s|verify "x", threshold: :any\nreturn(:ok)|)
      assert f.message =~ "voters"
    end

    test "a non-literal subject is a located finding" do
      assert {:error, %Finding{} = f} = parse(~s|verify build_it(), voters: 3\nreturn(:ok)|)
      assert f.message =~ "literal"
    end
  end

  describe "judge (scoring panel)" do
    test "expands the candidate x criterion grid into pre-addressed, schema-bound scorers" do
      {:ok, tree} =
        parse(~s|judge ["a", "b"], by: [:quality, :risk], pick: :max_score\nreturn(:ok)|)

      assert [
               %Judge{
                 address: [0],
                 candidates: ["a", "b"],
                 by: [:quality, :risk],
                 pick: :max_score,
                 scorers: [
                   [
                     %Agent{
                       address: [0, 0, 0],
                       prompt: "Score this candidate on quality, answering with a numeric score: a",
                       schema: sc
                     },
                     %Agent{
                       address: [0, 0, 1],
                       prompt: "Score this candidate on risk, answering with a numeric score: a"
                     }
                   ],
                   [%Agent{address: [0, 1, 0]}, %Agent{address: [0, 1, 1]}]
                 ]
               },
               %Return{}
             ] = tree.nodes

      schema = Schema.to_map(sc)
      assert schema["required"] == ["score"]
      assert schema["properties"]["score"] == %{"type" => "number"}
      refute contains_function?(tree)
    end

    test "min_score is an accepted pick strategy" do
      {:ok, tree} = parse(~s|judge ["a"], by: [:c], pick: :min_score\nreturn(:ok)|)
      assert [%Judge{pick: :min_score}, _] = tree.nodes
    end

    test "an out-of-vocabulary pick is a located finding" do
      assert {:error, %Finding{} = f} =
               parse(~s|judge ["a"], by: [:c], pick: :random\nreturn(:ok)|)

      assert f.message =~ "out of vocabulary"
    end

    test "non-literal candidates are a located finding" do
      assert {:error, %Finding{} = f} =
               parse(~s|judge gather(), by: [:c], pick: :max_score\nreturn(:ok)|)

      assert f.message =~ "literal list"
    end

    test "missing criteria is a located finding" do
      assert {:error, %Finding{} = f} = parse(~s|judge ["a"], pick: :max_score\nreturn(:ok)|)
      assert f.message =~ "by:"
    end
  end

  describe "synthesize" do
    test "compiles literal inputs and a static prompt into an inert node" do
      {:ok, tree} = parse(~s|synthesize ["a", "b"], "merge them"\nreturn(:ok)|)

      assert [%Synthesize{address: [0], inputs: ["a", "b"], prompt: "merge them"}, %Return{}] =
               tree.nodes

      refute contains_function?(tree)
    end

    test "a non-literal inputs term is a located finding" do
      assert {:error, %Finding{} = f} = parse(~s|synthesize gather(), "merge"\nreturn(:ok)|)
      assert f.message =~ "literal"
    end

    test "a non-literal prompt is a located finding" do
      assert {:error, %Finding{} = f} = parse(~s|synthesize ["a"], compute()\nreturn(:ok)|)
      assert f.message =~ "literal string"
    end
  end

  describe "refine" do
    test "compiles an inline producer and static reviewer panel into pre-addressed role agents" do
      {:ok, tree} =
        parse("""
        refine agent("Draft."),
          reviewers: [reviewer(:spec, "Spec review."), reviewer(:runtime, "Runtime review.")],
          revise_with: agent("Fix it."),
          until: :unanimous,
          max_rounds: 3
        return(:ok)
        """)

      assert [
               %Refine{
                 address: [0],
                 input: {:producer, %Agent{address: [0, 0], prompt: "Draft.", schema: artifact_schema}},
                 reviewers: [
                   %{
                     index: 0,
                     name: :spec,
                     prompt: "Spec review.",
                     agent: %Agent{address: [0, 1, 0], schema: review_schema, retries: 0}
                   },
                   %{
                     index: 1,
                     name: :runtime,
                     prompt: "Runtime review.",
                     agent: %Agent{address: [0, 1, 1], retries: 0}
                   }
                 ],
                 reviser: %Agent{address: [0, 2], prompt: "Fix it."},
                 until: :unanimous,
                 max_rounds: 3,
                 max_concurrency: 2
               },
               %Return{value: :ok}
             ] = tree.nodes

      artifact_schema = Schema.to_map(artifact_schema)
      review_schema = Schema.to_map(review_schema)
      assert artifact_schema["required"] == ["artifact"]
      assert artifact_schema["additionalProperties"] == false
      assert review_schema["required"] == ["approved", "findings"]
      assert review_schema["additionalProperties"] == false
      assert review_schema["properties"]["findings"]["items"]["additionalProperties"] == false
      refute contains_function?(tree)
    end
  end

  describe "fan_out (budget-scaled)" do
    test "compiles width: budget_slices(per: N) into an inert width and a body lane" do
      {:ok, tree} =
        parse("""
        fan_out width: budget_slices(per: 10) do
          agent "work"
        end
        return :ok
        """)

      assert [
               %GenericFanout{
                 address: [0],
                 width: %BudgetSlices{per: 10},
                 max_concurrency: nil,
                 lanes: {:repeat, [%Agent{address: [0], prompt: "work"}]}
               },
               %Return{}
             ] = tree.nodes

      refute contains_function?(tree)
    end

    test "carries an optional concurrency cap" do
      {:ok, tree} =
        parse("fan_out width: budget_slices(per: 4), max_concurrency: 2 do\n agent \"w\"\nend\nreturn :ok")

      assert [%GenericFanout{max_concurrency: 2}, _] = tree.nodes
    end

    test "a width that is not budget_slices is a located finding (no author arithmetic)" do
      assert {:error, %Finding{} = f} =
               parse("fan_out width: 3 do\n agent \"w\"\nend\nreturn :ok")

      assert f.message =~ "budget_slices(per: N)"
    end

    test "an empty body is a located finding" do
      assert {:error, %Finding{} = f} =
               parse("fan_out width: budget_slices(per: 2) do\nend\nreturn :ok")

      assert f.message =~ "at least one body step"
    end

    test "a non-agent body step is a located finding" do
      assert {:error, %Finding{} = f} =
               parse("fan_out width: budget_slices(per: 2) do\n log \"x\"\nend\nreturn :ok")

      assert f.message =~ "must be `agent`"
    end

    test "a closure in the body returns a forbidden-form finding" do
      assert {:error, %Finding{message: message}} =
               parse("fan_out width: budget_slices(per: 2) do\n fn -> :x end\nend\nreturn :ok")

      assert message =~ "anonymous functions"
    end
  end

  describe "quality combinators are rejected inside a loop body" do
    for combinator <- ~w(verify judge synthesize fan_out) do
      test "#{combinator} is not allowed inside a loop body" do
        src =
          "while_budget reserve: 1 do\n  #{unquote(combinator)} \"x\", voters: 1\nend\nreturn :ok"

        assert {:error, %Finding{} = f} = parse(src)
        assert f.message =~ "not allowed inside a loop body"
      end
    end
  end

  # A term with no functions anywhere: proves inertness/serializability of the tree.
  defp contains_function?(term) when is_function(term), do: true
  defp contains_function?(%_{} = s), do: s |> Map.from_struct() |> contains_function?()

  defp contains_function?(m) when is_map(m), do: m |> Map.values() |> Enum.any?(&contains_function?/1)

  defp contains_function?(l) when is_list(l), do: Enum.any?(l, &contains_function?/1)

  defp contains_function?(t) when is_tuple(t), do: t |> Tuple.to_list() |> Enum.any?(&contains_function?/1)

  defp contains_function?(_), do: false
end
