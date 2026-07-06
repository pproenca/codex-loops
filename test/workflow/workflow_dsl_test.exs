defmodule Workflow.DSLTest do
  @moduledoc "The thin macro produces an inert `__workflow__/1` reflection."
  use ExUnit.Case, async: true

  defmodule DemoWorkflow do
    use Workflow

    workflow "demo" do
      phase("p")
      log("hi")
      agent("say hello")
      return(:ok)
    end
  end

  test "exposes the compiled tree as inert data via __workflow__/1" do
    assert DemoWorkflow.__workflow__(:name) == "demo"

    tree = DemoWorkflow.__workflow__(:tree)
    assert %Workflow.Tree{name: "demo", version: 1} = tree
    assert length(tree.nodes) == 4
    refute contains_function?(tree)
  end

  test "an unknown form in a workflow body fails compilation" do
    source = """
    defmodule Rejected.UnknownForm do
      use Workflow

      workflow "bad" do
        phase "p"
        danger_zone "boom"
      end
    end
    """

    assert_raise Workflow.CompileError, fn -> Code.compile_string(source) end
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
