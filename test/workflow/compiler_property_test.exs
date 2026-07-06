defmodule Workflow.CompilerPropertyTest do
  @moduledoc """
  The determinism invariant, stated as a property: every workflow the compiler
  *accepts* is built purely from the closed, deterministic node vocabulary and
  contains no closures — there is no node that can express randomness or
  wall-clock, so an accepted tree can never contain one. A companion property
  asserts the forbidden-form catalog rejects escape hatches under generation.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Workflow.Compiler
  alias Workflow.Node.{Phase, Log, Agent, Return}

  @deterministic_nodes [Phase, Log, Agent, Return]

  property "every accepted workflow tree is built only from deterministic nodes" do
    check all statements <- list_of(one_of([:phase, :log, :agent]), max_length: 12) do
      # Unique phase names keep every generated body well-formed (accepted), so the
      # property speaks about the accept path; a trailing return makes it terminate.
      body =
        statements
        |> Enum.with_index()
        |> Enum.map(fn {kind, i} -> {kind, [line: i + 1], ["#{kind}_#{i}"]} end)
        |> then(&{:__block__, [], &1 ++ [{:return, [line: 999], [:ok]}]})

      assert {:ok, tree} = Compiler.parse(body, __ENV__)
      assert Enum.all?(tree.nodes, &(&1.__struct__ in @deterministic_nodes))
      refute contains_function?(tree)
    end
  end

  property "forbidden forms are always rejected at compile" do
    forbidden =
      one_of([
        constant(quote(do: :rand.uniform())),
        constant(quote(do: System.monotonic_time())),
        constant(quote(do: System.os_time())),
        constant(quote(do: Enum.map([], fn x -> x end))),
        constant(quote(do: fn -> :escape end)),
        constant(quote(do: :erlang.now()))
      ])

    check all form <- forbidden do
      body = {:__block__, [], [form, {:return, [line: 2], [:ok]}]}
      assert_raise Workflow.CompileError, fn -> Compiler.parse(body, __ENV__) end
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
