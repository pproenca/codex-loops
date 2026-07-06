defmodule Workflow.CompilerTest do
  @moduledoc """
  Exercises the DSL at its highest seam — `Workflow.Compiler.parse/2` — directly
  against `quote do ... end` input, with no macro expansion involved.
  """
  use ExUnit.Case, async: true

  alias Workflow.Compiler
  alias Workflow.Compiler.Finding
  alias Workflow.Node.{Phase, Log, Agent, Return}

  test "parses the demo body into an ordered, addressed, inert tree" do
    body =
      quote do
        phase("p")
        log("hi")
        agent("say hello")
        return(:ok)
      end

    assert {:ok, tree} = Compiler.parse(body, __ENV__)

    assert [
             %Phase{address: [0], name: "p"},
             %Log{address: [1], message: "hi"},
             %Agent{address: [2], prompt: "say hello"},
             %Return{address: [3], value: :ok}
           ] = tree.nodes
  end

  test "parses a single-statement body (not wrapped in a __block__)" do
    assert {:ok, tree} = Compiler.parse(quote(do: log("only")), __ENV__)
    assert [%Log{address: [0], message: "only"}] = tree.nodes
  end

  test "the tree contains no closures anywhere in the term" do
    {:ok, tree} = Compiler.parse(quote(do: agent("go")), __ENV__)
    refute contains_function?(tree)
  end

  test "raises on an unknown form outside the vocabulary" do
    body =
      quote do
        phase("p")
        frobnicate("boom")
      end

    assert_raise Workflow.CompileError, ~r/unknown workflow form/, fn ->
      Compiler.parse(body, __ENV__)
    end
  end

  test "raises on a closure — the forbidden fn -> ... end form" do
    body = quote(do: fn -> :nope end)

    assert_raise Workflow.CompileError, fn ->
      Compiler.parse(body, __ENV__)
    end
  end

  test "returns a finding for a known combinator with the wrong argument shape" do
    assert {:error, %Finding{}} = Compiler.parse(quote(do: agent(:not_a_string)), __ENV__)
    assert {:error, %Finding{}} = Compiler.parse(quote(do: phase("a", "b")), __ENV__)
  end

  test "returns a finding when return is given a non-literal value" do
    assert {:error, %Finding{}} = Compiler.parse(quote(do: return(compute())), __ENV__)
  end

  # A term with no functions anywhere: proves inertness/serializability.
  defp contains_function?(term) when is_function(term), do: true

  defp contains_function?(%_{} = struct),
    do: struct |> Map.from_struct() |> contains_function?()

  defp contains_function?(map) when is_map(map),
    do: map |> Map.values() |> Enum.any?(&contains_function?/1)

  defp contains_function?(list) when is_list(list),
    do: Enum.any?(list, &contains_function?/1)

  defp contains_function?(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> Enum.any?(&contains_function?/1)

  defp contains_function?(_other), do: false
end
