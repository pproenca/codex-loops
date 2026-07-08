defmodule Workflow.PredicateTest do
  @moduledoc """
  The closed predicate sub-vocabulary at its highest seams: `Predicate.parse/2`
  against `quote`d input (no macro expansion) for the grammar, and
  `Predicate.evaluate/2` against a plain folded context for the semantics. Anything
  outside the vocabulary is rejected at parse (compile) time.
  """
  use ExUnit.Case, async: true

  alias Workflow.Predicate

  alias Workflow.Predicate.{
    Agree,
    AllOf,
    AnyOf,
    BudgetRemaining,
    Compare,
    Count,
    Dry,
    PathCount,
    PathEquals,
    PathExists,
    PathNonEmpty
  }

  alias Workflow.Compiler.Finding

  defp parse(source, binding_env \\ %{}),
    do: Predicate.parse(Code.string_to_quoted!(source), __ENV__, binding_env)

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

    test "all / any are the live names, with legacy aliases preserved" do
      assert {:ok, %AllOf{predicates: [%Compare{left: %Count{acc: :a}}]}} =
               parse("all([count(:a) >= 1])")

      assert {:ok, %AnyOf{predicates: [%Compare{left: %Count{acc: :b}}]}} =
               parse("any([count(:b) >= 1])")

      assert {:ok, %AllOf{}} = parse("all_of([count(:legacy) >= 1])")
      assert {:ok, %AnyOf{}} = parse("any_of([count(:legacy) >= 1])")
    end

    test "dry predicate carries rounds and optional seen_by atoms" do
      assert {:ok, %Dry{rounds: 2, seen_by: [:id, :path]}} =
               parse("dry(rounds: 2, seen_by: [:id, :path])")

      assert {:ok, %Dry{rounds: 1, seen_by: []}} =
               parse("dry(rounds: 1)")
    end

    test "path predicates resolve literal binding atoms to explicit binding refs" do
      bindings = %{reviews: {:map, [0]}}

      assert {:ok,
              %Compare{
                op: :>=,
                left: %PathCount{binding: :reviews, ref: {:map, [0]}, pointer: "/items"},
                right: 2
              }} =
               parse(~s|path_count(:reviews, "/items") >= 2|, bindings)

      assert {:ok, %PathExists{binding: :reviews, ref: {:map, [0]}, pointer: ""}} =
               parse(~s|path_exists(:reviews, "")|, bindings)

      assert {:ok, %PathNonEmpty{binding: :reviews, ref: {:map, [0]}, pointer: "/summary"}} =
               parse(~s|path_non_empty(:reviews, "/summary")|, bindings)

      assert {:ok,
              %PathEquals{binding: :reviews, ref: {:map, [0]}, pointer: "/ok", literal: true}} =
               parse(~s|path_equals(:reviews, "/ok", true)|, bindings)
    end

    test "agree normalizes JSON literals and thresholds" do
      bindings = %{reviews: {:map, [0]}}

      assert {:ok,
              %Agree{
                binding: :reviews,
                ref: {:map, [0]},
                pointer: "/result",
                literal: %{"ok" => true, "label" => "ready"},
                threshold: :all
              }} =
               parse(
                 ~s|agree(:reviews, path: "/result", equals: %{ok: true, label: :ready}, threshold: :all)|,
                 bindings
               )

      assert {:ok, %Agree{threshold: 2}} =
               parse(~s|agree(:reviews, path: "/ok", equals: true, threshold: 2)|, bindings)
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

    test "all and any require at least one nested predicate" do
      assert {:error, %Finding{} = f} = parse("all([])")
      assert f.message =~ "requires at least one predicate"

      assert {:error, %Finding{}} = parse("any([])")
    end

    test "dry validates rounds and seen_by" do
      assert {:error, %Finding{} = f} = parse("dry(rounds: 0)")
      assert f.message =~ "rounds"

      assert {:error, %Finding{} = f} = parse(~s|dry(rounds: 1, seen_by: ["id"])|)
      assert f.message =~ "seen_by"
    end

    test "path and agreement predicates require known binding refs" do
      assert {:error, %Finding{} = f} = parse(~s|path_exists(:reviews, "")|)
      assert f.message =~ "unknown binding"

      assert {:error, %Finding{} = f} =
               parse(~s|agree("reviews", path: "", equals: true, threshold: :all)|, %{
                 reviews: {:map, [0]}
               })

      assert f.message =~ "binding"
    end

    test "JSON pointers must be literal RFC 6901 pointers with valid escapes" do
      assert {:error, %Finding{} = f} =
               parse(~s|path_equals(:reviews, "open", true)|, %{reviews: {:map, [0]}})

      assert f.message =~ "JSON pointer"

      assert {:error, %Finding{} = f} =
               parse(~s|path_exists(:reviews, "/bad~2escape")|, %{reviews: {:map, [0]}})

      assert f.message =~ "JSON pointer"
    end

    test "path and agreement literals must be JSON-convertible without duplicate object keys" do
      bindings = %{reviews: {:map, [0]}}

      assert {:error, %Finding{} = f} =
               parse(~s|path_equals(:reviews, "", %{:a => 1, "a" => 2})|, bindings)

      assert f.message =~ "duplicate"

      assert {:error, %Finding{} = f} =
               parse(~s|path_equals(:reviews, "", {1, 2})|, bindings)

      assert f.message =~ "JSON"

      assert {:error, %Finding{} = f} =
               parse(~s|path_equals(:reviews, "", fn -> true end)|, bindings)

      assert f.message =~ "JSON"
    end

    test "agreement thresholds are closed and typed" do
      bindings = %{reviews: {:map, [0]}}

      assert {:error, %Finding{} = f} =
               parse(~s|agree(:reviews, path: "/ok", equals: true, threshold: :most)|, bindings)

      assert f.message =~ "threshold"

      assert {:error, %Finding{} = f} =
               parse(~s|agree(:reviews, path: "/ok", equals: true, threshold: 0)|, bindings)

      assert f.message =~ "threshold"
    end
  end

  describe "evaluation over a folded context" do
    defp ctx(accumulators, remaining, opts \\ []) do
      %{
        accumulators: accumulators,
        remaining: remaining,
        dry_streak: Keyword.get(opts, :dry_streak, 0),
        bindings: Keyword.get(opts, :bindings, %{})
      }
    end

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

    test "dry compares against the folded dry streak" do
      assert Predicate.evaluate(%Dry{rounds: 2, seen_by: [:id]}, ctx(%{}, 0, dry_streak: 2))
      refute Predicate.evaluate(%Dry{rounds: 3, seen_by: [:id]}, ctx(%{}, 0, dry_streak: 2))
    end

    test "path predicates use JSON Pointer over explicit binding refs" do
      c =
        ctx(%{}, 0,
          bindings: %{
            {:map, [0]} => %{
              "items" => [%{"id" => 1}, %{"id" => 2}],
              :summary => "done",
              "empty" => [],
              "a/b" => %{"~key" => false}
            }
          }
        )

      assert Predicate.evaluate(
               %PathExists{ref: {:map, [0]}, binding: :reviews, pointer: "/items/0"},
               c
             )

      assert Predicate.evaluate(
               %PathNonEmpty{ref: {:map, [0]}, binding: :reviews, pointer: "/summary"},
               c
             )

      refute Predicate.evaluate(
               %PathNonEmpty{ref: {:map, [0]}, binding: :reviews, pointer: "/empty"},
               c
             )

      assert Predicate.evaluate(
               %PathEquals{
                 ref: {:map, [0]},
                 binding: :reviews,
                 pointer: "/a~1b/~0key",
                 literal: false
               },
               c
             )

      assert Predicate.evaluate(
               %Compare{
                 op: :==,
                 left: %PathCount{ref: {:map, [0]}, binding: :reviews, pointer: "/items"},
                 right: 2
               },
               c
             )

      refute Predicate.evaluate(
               %PathExists{ref: {:map, [0]}, binding: :reviews, pointer: "/items/01"},
               c
             )

      refute Predicate.evaluate(
               %PathExists{ref: {:node, [99]}, binding: :missing, pointer: ""},
               c
             )
    end

    test "path lookup prefers string map keys before existing atom keys" do
      c =
        ctx(%{}, 0,
          bindings: %{
            {:node, [1]} => %{"name" => "string", name: "atom"}
          }
        )

      assert Predicate.evaluate(
               %PathEquals{
                 ref: {:node, [1]},
                 binding: :item,
                 pointer: "/name",
                 literal: "string"
               },
               c
             )
    end

    test "agreement counts JSON-equal list items without vacuous all" do
      c =
        ctx(%{}, 0,
          bindings: %{
            {:map, [0]} => [
              %{"approved" => true},
              %{"approved" => true},
              %{"approved" => false}
            ],
            {:map, [1]} => []
          }
        )

      assert Predicate.evaluate(
               %Agree{
                 ref: {:map, [0]},
                 binding: :reviews,
                 pointer: "/approved",
                 literal: true,
                 threshold: :any
               },
               c
             )

      assert Predicate.evaluate(
               %Agree{
                 ref: {:map, [0]},
                 binding: :reviews,
                 pointer: "/approved",
                 literal: true,
                 threshold: 2
               },
               c
             )

      refute Predicate.evaluate(
               %Agree{
                 ref: {:map, [0]},
                 binding: :reviews,
                 pointer: "/approved",
                 literal: true,
                 threshold: :all
               },
               c
             )

      refute Predicate.evaluate(
               %Agree{
                 ref: {:map, [1]},
                 binding: :empty,
                 pointer: "/approved",
                 literal: true,
                 threshold: :all
               },
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
