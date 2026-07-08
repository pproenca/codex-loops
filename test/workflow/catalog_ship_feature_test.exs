defmodule Workflow.Catalog.ShipFeatureTest do
  use ExUnit.Case, async: true

  alias Workflow.Catalog.ShipFeature
  alias Workflow.Tree

  # Recursively walk any term; fail loudly if a function/closure hides in it.
  defp assert_closure_free(t) when is_function(t),
    do: flunk("closure found in compiled tree: #{inspect(t)}")

  defp assert_closure_free(%_{} = s),
    do: s |> Map.from_struct() |> Map.values() |> Enum.each(&assert_closure_free/1)

  defp assert_closure_free(m) when is_map(m),
    do: m |> Map.values() |> Enum.each(&assert_closure_free/1)

  defp assert_closure_free(l) when is_list(l), do: Enum.each(l, &assert_closure_free/1)

  defp assert_closure_free(t) when is_tuple(t),
    do: t |> Tuple.to_list() |> Enum.each(&assert_closure_free/1)

  defp assert_closure_free(_), do: :ok

  test "the flagship workflow compiles to an inert %Tree{}" do
    assert %Tree{nodes: nodes} = ShipFeature.__workflow__(:tree)
    assert is_list(nodes) and nodes != []
  end

  test "the compiled tree is entirely closure-free inert data" do
    assert_closure_free(ShipFeature.__workflow__(:tree))
  end

  test "it composes the full combinator vocabulary in one run" do
    %Tree{nodes: nodes} = ShipFeature.__workflow__(:tree)
    kinds = MapSet.new(nodes, & &1.__struct__)

    for node_mod <- [
          Workflow.Node.Log,
          Workflow.Node.Phase,
          Workflow.Node.Parallel,
          Workflow.Node.Pipeline,
          Workflow.Node.WhileBudget,
          Workflow.Node.UntilDry,
          Workflow.Node.Verify,
          Workflow.Node.Judge,
          Workflow.Node.FanOut,
          Workflow.Node.Synthesize,
          Workflow.Node.Return
        ] do
      assert node_mod in kinds, "expected the flagship to use #{inspect(node_mod)}"
    end
  end
end
