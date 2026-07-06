defmodule Workflow.PredicateTest do
  @moduledoc """
  The closed predicate sub-vocabulary at its highest seams: `Predicate.parse/2`
  against `quote`d input (no macro expansion) for the grammar, and
  `Predicate.evaluate/2` against a plain folded context for the semantics. Anything
  outside the vocabulary is rejected at parse (compile) time.
  """
  use ExUnit.Case, async: true

  alias Workflow.Predicate
  alias Workflow.Predicate.{Count, BudgetRemaining, Compare, AllOf, AnyOf}
  alias Workflow.Compiler.Finding

  defp parse(source), do: Predicate.parse(Code.string_to_quoted!(source), __ENV__)

  describe "parsing the closed vocabulary" do
    test "count(:acc) compared to a literal integer" do
      assert {:ok, %Compare{op: :>=, left: %Count{acc: :items}, right: 3}} =
               parse("count(:items) >= 3")

      assert {:ok, %Compare{op: :<, left: %Count{acc: :seen}, right: 10}} =
               parse("count(:seen) < 10")
    end

    test "budget_remaining() compared to a literal integer" do
      assert {:ok, %Compare{op: :>, left: %BudgetRemaining{}, right: 5}} =
               parse("budget_remaining() > 5")
    end

    test "all_of / any_of over nested predicates" do
      assert {:ok,
              %AllOf{
                predicates: [%Compare{left: %Count{acc: :a}}, %Compare{left: %BudgetRemaining{}}]
              }} =
               parse("all_of([count(:a) >= 1, budget_remaining() > 2])")

      assert {:ok, %AnyOf{predicates: [%Compare{}, %AllOf{}]}} =
               parse("any_of([count(:a) == 0, all_of([count(:b) >= 1, count(:c) >= 1])])")
    end

    test "the parsed predicate holds no closures" do
      {:ok, pred} = parse("all_of([count(:a) >= 1, budget_remaining() > 2])")
      refute contains_function?(pred)
    end
  end

  describe "rejecting anything outside the vocabulary (compile-time findings)" do
    test "arithmetic on an operand is not part of the grammar" do
      assert {:error, %Finding{}} = parse("count(:a) * 2 >= 3")
    end

    test "an arbitrary function call is not an operand" do
      assert {:error, %Finding{} = f} = parse("some_metric() > 1")
      assert f.message =~ "operand"
    end

    test "a non-literal threshold is rejected" do
      assert {:error, %Finding{} = f} = parse("count(:a) >= n")
      assert f.message =~ "literal integer"
    end

    test "an unknown top-level form is rejected" do
      assert {:error, %Finding{}} = parse("count(:a)")
      assert {:error, %Finding{}} = parse("not count(:a) >= 1")
    end

    test "count needs an atom accumulator name" do
      assert {:error, %Finding{}} = parse(~s|count("a") >= 1|)
    end
  end

  describe "evaluation over a folded context" do
    defp ctx(accumulators, remaining), do: %{accumulators: accumulators, remaining: remaining}

    test "count reads the accumulator size" do
      c = ctx(%{items: [1, 2, 3]}, 100)
      assert Predicate.evaluate(%Compare{op: :>=, left: %Count{acc: :items}, right: 3}, c)
      refute Predicate.evaluate(%Compare{op: :>, left: %Count{acc: :items}, right: 3}, c)
      # A never-collected accumulator counts as empty.
      assert Predicate.evaluate(%Compare{op: :==, left: %Count{acc: :missing}, right: 0}, c)
    end

    test "budget_remaining reads the ledger remaining, with :infinity for unbounded" do
      assert Predicate.evaluate(
               %Compare{op: :>, left: %BudgetRemaining{}, right: 5},
               ctx(%{}, 10)
             )

      refute Predicate.evaluate(
               %Compare{op: :>, left: %BudgetRemaining{}, right: 50},
               ctx(%{}, 10)
             )

      # :infinity sorts above every integer, matching the ledger.
      assert Predicate.evaluate(
               %Compare{op: :>, left: %BudgetRemaining{}, right: 999_999},
               ctx(%{}, :infinity)
             )
    end

    test "all_of and any_of combine nested predicates" do
      c = ctx(%{a: [1], b: []}, 3)

      all = %AllOf{
        predicates: [
          %Compare{op: :>=, left: %Count{acc: :a}, right: 1},
          %Compare{op: :>, left: %BudgetRemaining{}, right: 2}
        ]
      }

      any = %AnyOf{
        predicates: [
          %Compare{op: :>=, left: %Count{acc: :b}, right: 1},
          %Compare{op: :>, left: %BudgetRemaining{}, right: 2}
        ]
      }

      assert Predicate.evaluate(all, c)
      assert Predicate.evaluate(any, c)

      refute Predicate.evaluate(
               %AllOf{predicates: [%Compare{op: :>=, left: %Count{acc: :b}, right: 1}]},
               c
             )
    end
  end

  defp contains_function?(term) when is_function(term), do: true
  defp contains_function?(%_{} = s), do: s |> Map.from_struct() |> contains_function?()

  defp contains_function?(m) when is_map(m),
    do: m |> Map.values() |> Enum.any?(&contains_function?/1)

  defp contains_function?(l) when is_list(l), do: Enum.any?(l, &contains_function?/1)

  defp contains_function?(t) when is_tuple(t),
    do: t |> Tuple.to_list() |> Enum.any?(&contains_function?/1)

  defp contains_function?(_), do: false
end
