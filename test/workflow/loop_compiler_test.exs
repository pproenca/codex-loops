defmodule Workflow.LoopCompilerTest do
  @moduledoc """
  The dynamic-loop DSL at its highest seam — `Workflow.Compiler.parse/2` — against
  `quote`d / string-sourced input with no macro expansion. Proves loops compile into
  inert, addressed, closure-free structs and that malformed loops are rejected with
  located findings.
  """
  use ExUnit.Case, async: true

  alias Workflow.Compiler
  alias Workflow.Compiler.Finding
  alias Workflow.Node.{Agent, Collect, WhileBudget, UntilDry}
  alias Workflow.Predicate.{Compare, Count}

  defp env, do: %{__ENV__ | file: "workflows/loops.ex", line: 1}
  defp parse(source), do: Compiler.parse(Code.string_to_quoted!(source), env())

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
               %WhileBudget{
                 address: [0],
                 reserve: 8,
                 until: nil,
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

      assert [%WhileBudget{until: %Compare{op: :>=, left: %Count{acc: :items}, right: 3}}, _] =
               tree.nodes

      refute contains_function?(tree)
    end

    test "requires reserve" do
      assert {:error, %Finding{} = f} =
               parse("while_budget max_iterations: 3 do\n  agent \"w\"\nend\nreturn :ok")

      assert f.message =~ "reserve"
    end

    test "an out-of-vocabulary predicate is rejected at compile time" do
      assert {:error, %Finding{}} =
               parse(
                 "while_budget reserve: 0, until: count(:a) * 2 >= 3 do\n  agent \"w\"\nend\nreturn :ok"
               )
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
               %UntilDry{
                 address: [0],
                 rounds: 2,
                 seen_by: [:file, :line],
                 body: [%Agent{address: [0, 0]}, %Collect{address: [0, 1], into: :findings}]
               },
               _return
             ] = tree.nodes

      refute contains_function?(tree)
    end

    test "requires a positive rounds" do
      assert {:error, %Finding{} = f} =
               parse(
                 "until_dry rounds: 0, seen_by: [:id] do\n  agent \"s\"\n  collect into: :x\nend\nreturn :ok"
               )

      assert f.message =~ "rounds"
    end

    test "seen_by must be a field list, never a function" do
      assert {:error, %Finding{} = f} =
               parse(
                 "until_dry rounds: 1, seen_by: fn x -> x end do\n  agent \"s\"\n  collect into: :x\nend\nreturn :ok"
               )

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

    test "a closure inside a loop body still raises via the forbidden-form catalog" do
      assert_raise Workflow.CompileError, fn ->
        parse("while_budget reserve: 1 do\n  fn -> :x end\nend\nreturn :ok")
      end
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
