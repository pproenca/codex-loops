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

  alias Workflow.Node.{
    Agent,
    BudgetSlices,
    Emit,
    GenericFanout,
    Parallel,
    PathCount,
    Pipeline,
    Return
  }

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

  describe "fanout (generic repeated lane)" do
    test "compiles an integer width into a repeated non-empty agent lane" do
      {:ok, tree} =
        parse("""
        fanout width: 3 do
          agent "work"
          agent "check"
        end
        return :ok
        """)

      assert [
               %GenericFanout{
                 address: [0],
                 width: 3,
                 lanes: [
                   [
                     %Agent{address: [0], prompt: "work"},
                     %Agent{address: [0], prompt: "check"}
                   ]
                 ],
                 repeated: true,
                 on_zero: :complete,
                 max_concurrency: nil,
                 bind: nil
               },
               %Return{}
             ] = tree.nodes

      refute contains_function?(tree)
    end

    test "binds the ordered fanout result list after the fanout node" do
      {:ok, tree} =
        parse("""
        fanout width: 2, bind: :reviews do
          agent "review"
        end

        emit ~P"Reviews: <%= @reviews %>"
        """)

      assert [
               %GenericFanout{address: [0], bind: :reviews},
               %Emit{bindings: %{reviews: {:fanout, [0], :global}}}
             ] = tree.nodes
    end

    test "carries optional max_concurrency and on_zero controls" do
      {:ok, tree} =
        parse("""
        fanout width: 0, max_concurrency: 1, on_zero: :fail do
          agent "work"
        end
        return :ok
        """)

      assert [%GenericFanout{width: 0, max_concurrency: 1, on_zero: :fail}, %Return{}] =
               tree.nodes
    end

    test "compiles budget_slices width with an explicit max cap" do
      {:ok, tree} =
        parse("""
        fanout width: budget_slices(per: 10, max: 3) do
          agent "work"
        end
        return :ok
        """)

      assert [%GenericFanout{width: %BudgetSlices{per: 10, max: 3}}, %Return{}] = tree.nodes
    end

    test "compiles path_count width against a lexically preceding binding" do
      {:ok, tree} =
        parse("""
        let :items = agent("items")
        fanout width: path_count(:items, "/rows", max: 4) do
          agent "work"
        end
        return :ok
        """)

      assert [
               %Agent{address: [0]},
               %GenericFanout{
                 address: [1],
                 width: %PathCount{
                   binding: :items,
                   ref: {:node, [0]},
                   pointer: "/rows",
                   max: 4
                 }
               },
               %Return{}
             ] = tree.nodes
    end

    test "rejects a width outside the closed WidthExpr grammar" do
      assert {:error, %Finding{} = f} =
               parse("fanout width: count(:items) do\n agent \"w\"\nend\nreturn :ok")

      assert f.message =~ "`fanout` width"
    end

    test "path_count width requires a preceding binding and an explicit positive max" do
      assert {:error, %Finding{} = f} =
               parse(
                 "fanout width: path_count(:items, \"/rows\", max: 4) do\n agent \"w\"\nend\nreturn :ok"
               )

      assert f.message =~ "unknown binding"

      assert {:error, %Finding{} = f} =
               parse("""
               let :items = agent("items")
               fanout width: path_count(:items, "/rows") do
                 agent "w"
               end
               return :ok
               """)

      assert f.message =~ "requires `max:`"
    end

    test "bind option validates atom names and rejects shadowing" do
      assert {:error, %Finding{} = f} =
               parse("""
               let :items = agent("items")
               fanout width: 1, bind: :items do
                 agent "w"
               end
               return :ok
               """)

      assert f.message =~ "already bound"

      assert {:error, %Finding{} = f} =
               parse("fanout width: 1, bind: true do\n agent \"w\"\nend\nreturn :ok")

      assert f.message =~ "`fanout bind:`"
    end

    test "rejects an empty repeated lane" do
      assert {:error, %Finding{} = f} = parse("fanout width: 2 do\nend\nreturn :ok")
      assert f.message =~ "at least one body step"
    end

    test "rejects invalid on_zero policy" do
      assert {:error, %Finding{} = f} =
               parse("fanout width: 0, on_zero: :skip do\n agent \"w\"\nend\nreturn :ok")

      assert f.message =~ "`on_zero`"
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
