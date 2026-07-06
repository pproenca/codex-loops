defmodule Workflow.FanoutCompilerTest do
  @moduledoc """
  The static fan-out combinators (`parallel`, `pipeline`) exercised at the highest
  DSL seam — `Workflow.Compiler.parse/2` — directly against `quote do ... end`
  input with no macro expansion. Assertions are on the inert, pre-addressed tree the
  compiler produces and on the located findings it returns for malformed fan-out.
  """
  use ExUnit.Case, async: true

  alias Workflow.Compiler
  alias Workflow.Compiler.Finding
  alias Workflow.Node.{Agent, Parallel, Pipeline, Return}

  defp env, do: %{__ENV__ | file: "workflows/demo.ex", line: 1}
  defp parse(source), do: Compiler.parse(Code.string_to_quoted!(source), env())

  describe "parallel (barrier fan-out)" do
    test "compiles a branch list into addressed, inert agent branches" do
      body =
        quote do
          parallel([agent("a"), agent("b"), agent("c")])
          return(:ok)
        end

      assert {:ok, tree} = Compiler.parse(body, env())

      assert [
               %Parallel{
                 address: [0],
                 max_concurrency: nil,
                 branches: [
                   %Agent{address: [0, 0], prompt: "a"},
                   %Agent{address: [0, 1], prompt: "b"},
                   %Agent{address: [0, 2], prompt: "c"}
                 ]
               },
               %Return{address: [1], value: :ok}
             ] = tree.nodes

      refute contains_function?(tree)
    end

    test "carries an explicit concurrency cap" do
      {:ok, tree} = parse(~s|parallel([agent("a"), agent("b")], max_concurrency: 1)\nreturn(:ok)|)
      assert [%Parallel{max_concurrency: 1}, %Return{}] = tree.nodes
    end

    test "a branch that is not an agent is a located finding" do
      assert {:error, %Finding{line: 1} = f} = parse(~s|parallel([log("x")])\nreturn(:ok)|)
      assert f.message =~ "branches must be `agent`"
    end

    test "an empty branch list is a located finding" do
      assert {:error, %Finding{} = f} = parse("parallel([])\nreturn(:ok)")
      assert f.message =~ "at least one branch"
    end

    test "a non-positive concurrency cap is a located finding" do
      assert {:error, %Finding{} = f} =
               parse(~s|parallel([agent("a")], max_concurrency: 0)\nreturn(:ok)|)

      assert f.message =~ "positive integer"
    end

    test "an unknown fan-out option is a located finding" do
      assert {:error, %Finding{} = f} =
               parse(~s|parallel([agent("a")], bogus: 1)\nreturn(:ok)|)

      assert f.message =~ "invalid fan-out options"
      assert f.hint =~ "max_concurrency"
    end

    test "a closure branch is rejected by the forbidden-form catalog (raises)" do
      assert_raise Workflow.CompileError, fn ->
        parse("parallel([fn -> :x end])\nreturn(:ok)")
      end
    end
  end

  describe "pipeline (per-item lanes)" do
    test "expands items × stages into pre-addressed inert lanes" do
      body =
        quote do
          pipeline(["x", "y"], [agent("s1"), agent("s2")])
          return(:ok)
        end

      assert {:ok, tree} = Compiler.parse(body, env())

      assert [
               %Pipeline{
                 address: [0],
                 items: ["x", "y"],
                 max_concurrency: nil,
                 lanes: [
                   [
                     %Agent{address: [0, 0, 0], prompt: "s1"},
                     %Agent{address: [0, 0, 1], prompt: "s2"}
                   ],
                   [
                     %Agent{address: [0, 1, 0], prompt: "s1"},
                     %Agent{address: [0, 1, 1], prompt: "s2"}
                   ]
                 ]
               },
               %Return{}
             ] = tree.nodes

      refute contains_function?(tree)
    end

    test "materializes a schema-backed stage into inert data on every lane" do
      body =
        quote do
          pipeline(["x"], [
            agent("classify", schema: %{"type" => "object", "required" => ["label"]})
          ])

          return(:ok)
        end

      assert {:ok, tree} = Compiler.parse(body, env())
      assert [%Pipeline{lanes: [[stage]]}, %Return{}] = tree.nodes

      assert %Agent{address: [0, 0, 0], schema: %{"type" => "object", "required" => ["label"]}} =
               stage

      refute contains_function?(tree)
    end

    test "carries an explicit concurrency cap" do
      {:ok, tree} = parse(~s|pipeline(["x", "y"], [agent("s")], max_concurrency: 1)\nreturn(:ok)|)
      assert [%Pipeline{max_concurrency: 1}, %Return{}] = tree.nodes
    end

    test "non-literal items are a located finding" do
      assert {:error, %Finding{line: 1} = f} =
               parse("pipeline(build_items(), [agent(\"s\")])\nreturn(:ok)")

      assert f.message =~ "literal list"
    end

    test "empty items are a located finding" do
      assert {:error, %Finding{} = f} = parse(~s|pipeline([], [agent("s")])\nreturn(:ok)|)
      assert f.message =~ "at least one item"
    end

    test "empty stages are a located finding" do
      assert {:error, %Finding{} = f} = parse(~s|pipeline(["x"], [])\nreturn(:ok)|)
      assert f.message =~ "at least one stage"
    end

    test "a stage that is not an agent is a located finding" do
      assert {:error, %Finding{} = f} = parse(~s|pipeline(["x"], [log("s")])\nreturn(:ok)|)
      assert f.message =~ "stages must be `agent`"
    end
  end

  # A term with no functions anywhere: proves inertness/serializability of the tree.
  defp contains_function?(term) when is_function(term), do: true
  defp contains_function?(%_{} = s), do: s |> Map.from_struct() |> contains_function?()

  defp contains_function?(m) when is_map(m),
    do: m |> Map.values() |> Enum.any?(&contains_function?/1)

  defp contains_function?(l) when is_list(l), do: Enum.any?(l, &contains_function?/1)

  defp contains_function?(t) when is_tuple(t),
    do: t |> Tuple.to_list() |> Enum.any?(&contains_function?/1)

  defp contains_function?(_), do: false
end
