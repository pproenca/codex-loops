defmodule Workflow.LoopCompilerTest do
  @moduledoc """
  The dynamic-loop DSL at its highest seam — `Workflow.Compiler.compile/3` — against
  `quote`d / string-sourced input with no macro expansion. Proves loops compile into
  inert, addressed, closure-free structs and that malformed loops are rejected with
  located findings.
  """
  use ExUnit.Case, async: true

  alias Workflow.Compiler
  alias Workflow.Compiler.Finding
  alias Workflow.Node.Agent
  alias Workflow.Node.Collect
  alias Workflow.Node.GenericFanout
  alias Workflow.Node.Loop
  alias Workflow.Node.Until
  alias Workflow.Predicate.Agree
  alias Workflow.Predicate.AllOf
  alias Workflow.Predicate.AnyOf
  alias Workflow.Predicate.BudgetRemaining
  alias Workflow.Predicate.Compare
  alias Workflow.Predicate.Count
  alias Workflow.Predicate.Dry

  defp env, do: %{__ENV__ | file: "workflows/loops.ex", line: 1}
  defp parse(source), do: Compiler.compile("test", Code.string_to_quoted!(source), env())

  describe "generic loop" do
    test "compiles a bounded loop with a header predicate and exhaustion policy" do
      {:ok, tree} =
        parse("""
        loop max_iterations: 3, until: count(:items) >= 2, on_exhausted: :fail do
          agent "work", schema: %{"type" => "array"}
          collect into: :items
        end
        return :ok
        """)

      assert [
               %Loop{
                 address: [0],
                 max_iterations: 3,
                 on_exhausted: :fail,
                 until: %Compare{op: :>=, left: %Count{acc: :items}, right: 2},
                 body: [
                   %Agent{address: [0, 0], prompt: "work"},
                   %Collect{address: [0, 1], into: :items}
                 ]
               },
               _return
             ] = tree.nodes

      refute contains_function?(tree)
    end

    test "compiles one body-local until at its source address" do
      {:ok, tree} =
        parse("""
        loop max_iterations: 5 do
          agent "work", schema: %{"type" => "array"}
          collect into: :items
          until count(:items) >= 2
          log "after"
        end
        return :ok
        """)

      assert [
               %Loop{
                 until: nil,
                 body: [
                   %Agent{address: [0, 0]},
                   %Collect{address: [0, 1]},
                   %Until{
                     address: [0, 2],
                     predicate: %Compare{op: :>=, left: %Count{acc: :items}, right: 2}
                   },
                   _
                 ]
               },
               _return
             ] = tree.nodes
    end

    test "body-local until can see earlier loop-local fanout bindings" do
      {:ok, tree} =
        parse("""
        loop max_iterations: 2 do
          fanout width: 1, bind: :checks do
            agent "check"
          end

          until agree(:checks, path: "/echo", equals: "check", threshold: :all)
        end
        return :ok
        """)

      assert [
               %Loop{
                 body: [
                   %GenericFanout{address: [0, 0], bind: :checks},
                   %Until{
                     predicate: %Agree{
                       binding: :checks,
                       ref: {:fanout, [0, 0], {:loop_local, [0]}}
                     }
                   }
                 ]
               },
               _return
             ] = tree.nodes
    end

    test "requires literal max_iterations and validates on_exhausted" do
      assert {:error, %Finding{} = f} =
               parse("""
               loop until: count(:items) >= 1 do
                 agent "work"
               end
               return :ok
               """)

      assert f.message =~ "max_iterations"

      assert {:error, %Finding{} = f} =
               parse("""
               loop max_iterations: 0 do
                 agent "work"
               end
               return :ok
               """)

      assert f.message =~ "max_iterations"

      assert {:error, %Finding{} = f} =
               parse("""
               loop max_iterations: 1, on_exhausted: :explode do
                 agent "work"
               end
               return :ok
               """)

      assert f.message =~ "on_exhausted"

      assert {:error, %Finding{} = f} =
               parse("loop max_iterations: 1001 do\n  agent \"work\"\nend\nreturn :ok")

      assert f.message =~ "between 1 and 1000"
    end

    test "rejects conflicting header and body until predicates" do
      assert {:error, %Finding{} = f} =
               parse("""
               loop max_iterations: 5, until: count(:items) >= 3 do
                 agent "work", schema: %{"type" => "array"}
                 collect into: :items
                 until count(:items) >= 1
               end
               return :ok
               """)

      assert f.message =~ "must not combine"
    end

    test "rejects multiple body until statements and dry predicates in body until" do
      assert {:error, %Finding{} = f} =
               parse("""
               loop max_iterations: 5 do
                 until count(:items) >= 1
                 until count(:items) >= 2
               end
               return :ok
               """)

      assert f.message =~ "at most one"

      assert {:error, %Finding{} = f} =
               parse("""
               loop max_iterations: 5 do
                 until dry(rounds: 1, seen_by: [:id])
               end
               return :ok
               """)

      assert f.message =~ "must not contain `dry`"
    end

    test "body until is only accepted in generic loop bodies" do
      assert {:error, %Finding{} = f} = parse("until count(:items) >= 1\nreturn :ok")
      assert f.message =~ "inside a generic `loop` body"

      assert {:error, %Finding{} = f} =
               parse("""
               while_budget reserve: 1 do
                 until count(:items) >= 1
               end
               return :ok
               """)

      assert f.message =~ "inside a generic `loop` body"
    end
  end

  describe "while_budget" do
    test "compiles into an inert node with an addressed, closure-free body" do
      {:ok, tree} =
        parse("""
        while_budget reserve: 8 do
          agent "work"
          collect into: :items
        end
        return :ok
        """)

      assert [
               %Loop{
                 address: [0],
                 until: %Compare{op: :<=, left: %BudgetRemaining{}, right: 8},
                 max_iterations: cap,
                 body: [
                   %Agent{address: [0, 0], prompt: "work"},
                   %Collect{address: [0, 1], into: :items}
                 ]
               },
               _return
             ] = tree.nodes

      assert is_integer(cap) and cap > 0
      refute contains_function?(tree)
    end

    test "carries an optional `until` predicate parsed into inert structs" do
      {:ok, tree} =
        parse("""
        while_budget reserve: 0, until: count(:items) >= 3 do
          agent "work"
          collect into: :items
        end
        return :ok
        """)

      assert [
               %Loop{
                 until: %AnyOf{
                   predicates: [
                     %Compare{op: :<=, left: %BudgetRemaining{}, right: 0},
                     %Compare{op: :>=, left: %Count{acc: :items}, right: 3}
                   ]
                 }
               },
               _
             ] = tree.nodes

      refute contains_function?(tree)
    end

    test "accepts dry predicates in until and keeps them inert" do
      {:ok, tree} =
        parse("""
        while_budget reserve: 0, until: dry(rounds: 1, seen_by: [:id]) do
          agent "work", schema: %{"type" => "array"}
          collect into: :items
        end
        return :ok
        """)

      assert [
               %Loop{
                 until: %AnyOf{
                   predicates: [
                     %Compare{op: :<=, left: %BudgetRemaining{}, right: 0},
                     %Dry{rounds: 1, seen_by: [:id]}
                   ]
                 }
               },
               _return
             ] = tree.nodes

      refute contains_function?(tree)
    end

    test "rejects conflicting dry seen_by lists inside nested predicates" do
      assert {:error, %Finding{} = f} =
               parse("""
               while_budget reserve: 0,
                            until: all([
                              dry(rounds: 1, seen_by: [:id]),
                              any_of([dry(rounds: 1, seen_by: [:url])])
                            ]) do
                 agent "work", schema: %{"type" => "array"}
                 collect into: :items
               end
               return :ok
               """)

      assert f.message =~ "conflicting `dry` seen_by"
    end

    test "allows matching dry seen_by lists inside nested predicates" do
      {:ok, tree} =
        parse("""
        while_budget reserve: 0,
                     until: all([
                       dry(rounds: 1, seen_by: [:id]),
                       any([dry(rounds: 2, seen_by: [:id])])
                     ]) do
          agent "work", schema: %{"type" => "array"}
          collect into: :items
        end
        return :ok
        """)

      assert [%Loop{until: %AnyOf{predicates: [_, %AllOf{predicates: [%Dry{}, %AnyOf{}]}]}}, _] =
               tree.nodes
    end

    test "allows all dry seen_by lists to be omitted" do
      {:ok, tree} =
        parse("""
        while_budget reserve: 0,
                     until: all([
                       dry(rounds: 1),
                       any([dry(rounds: 2)])
                     ]) do
          agent "work", schema: %{"type" => "array"}
          collect into: :items
        end
        return :ok
        """)

      assert [%Loop{until: %AnyOf{predicates: [_, %AllOf{predicates: [%Dry{}, %AnyOf{}]}]}}, _] =
               tree.nodes
    end

    test "requires reserve" do
      assert {:error, %Finding{} = f} =
               parse("while_budget max_iterations: 3 do\n  agent \"w\"\nend\nreturn :ok")

      assert f.message =~ "reserve"
    end

    test "an out-of-vocabulary predicate is rejected at compile time" do
      assert {:error, %Finding{}} =
               parse("while_budget reserve: 0, until: count(:a) * 2 >= 3 do\n  agent \"w\"\nend\nreturn :ok")
    end
  end

  describe "until_dry" do
    test "compiles into an inert node carrying rounds and a seen_by field list" do
      {:ok, tree} =
        parse("""
        until_dry rounds: 2, seen_by: [:file, :line] do
          agent "scan", schema: %{"type" => "array"}
          collect into: :findings
        end
        return :ok
        """)

      assert [
               %Loop{
                 address: [0],
                 until: %Dry{rounds: 2, seen_by: [:file, :line]},
                 body: [%Agent{address: [0, 0]}, %Collect{address: [0, 1], into: :findings}]
               },
               _return
             ] = tree.nodes

      refute contains_function?(tree)
    end

    test "requires a positive rounds" do
      assert {:error, %Finding{} = f} =
               parse("until_dry rounds: 0, seen_by: [:id] do\n  agent \"s\"\n  collect into: :x\nend\nreturn :ok")

      assert f.message =~ "rounds"
    end

    test "seen_by must be a field list, never a function" do
      assert {:error, %Finding{} = f} =
               parse("until_dry rounds: 1, seen_by: fn x -> x end do\n  agent \"s\"\n  collect into: :x\nend\nreturn :ok")

      assert f.message =~ "field list"
    end

    test "the body must collect into an accumulator" do
      assert {:error, %Finding{} = f} =
               parse("until_dry rounds: 1, seen_by: [:id] do\n  agent \"s\"\nend\nreturn :ok")

      assert f.message =~ "collect"
    end

    test "template prompts are rejected in until_dry loop bodies with the top-level-only finding" do
      assert {:error, %Finding{} = f} =
               parse("""
               let :draft = agent("Write a draft.")
               until_dry rounds: 1, seen_by: [:id] do
                 agent(~P"Improve: <%= @draft %>")
                 collect into: :items
               end
               return(:ok)
               """)

      assert f.message =~ "template prompts are only allowed on top-level agents"
      assert f.message =~ "loop body"
    end
  end

  describe "collect placement and shape" do
    test "collect at top level (outside a loop) is rejected" do
      assert {:error, %Finding{} = f} = parse("collect into: :items\nreturn :ok")
      assert f.message =~ "must appear inside a loop"
    end

    test "collect requires exactly into: :name" do
      assert {:error, %Finding{}} =
               parse("while_budget reserve: 1 do\n  collect into: :a, foo: 1\nend\nreturn :ok")

      assert {:error, %Finding{}} =
               parse("while_budget reserve: 1 do\n  collect into: \"a\"\nend\nreturn :ok")
    end
  end

  describe "loop-body vocabulary is closed" do
    test "a nested loop inside a loop body is rejected (keeps the iteration key a single integer)" do
      assert {:error, %Finding{} = f} =
               parse("""
               while_budget reserve: 1 do
                 while_budget reserve: 1 do
                   agent "inner"
                 end
               end
               return :ok
               """)

      assert f.message =~ "not allowed inside a loop body"
    end

    test "return inside a loop body is rejected" do
      assert {:error, %Finding{}} =
               parse("while_budget reserve: 1 do\n  return :ok\nend\nreturn :ok")
    end

    test "a closure inside a loop body returns a forbidden-form finding" do
      assert {:error, %Finding{message: message}} =
               parse("while_budget reserve: 1 do\n  fn -> :x end\nend\nreturn :ok")

      assert message =~ "anonymous functions"
    end
  end

  defp contains_function?(term) when is_function(term), do: true
  defp contains_function?(%_{} = s), do: s |> Map.from_struct() |> contains_function?()

  defp contains_function?(m) when is_map(m), do: m |> Map.values() |> Enum.any?(&contains_function?/1)

  defp contains_function?(l) when is_list(l), do: Enum.any?(l, &contains_function?/1)

  defp contains_function?(t) when is_tuple(t), do: t |> Tuple.to_list() |> Enum.any?(&contains_function?/1)

  defp contains_function?(_), do: false
end
