defmodule Workflow.Catalog.ShipFeatureTest do
  use ExUnit.Case, async: true

  alias Workflow.Catalog.ShipFeature
  alias Workflow.Node.EmitResult
  alias Workflow.Node.Refine
  alias Workflow.Tree

  # Recursively walk any term; fail loudly if a function/closure hides in it.
  defp assert_closure_free(t) when is_function(t), do: flunk("closure found in compiled tree: #{inspect(t)}")

  defp assert_closure_free(%_{} = s), do: s |> Map.from_struct() |> Map.values() |> Enum.each(&assert_closure_free/1)

  defp assert_closure_free(m) when is_map(m), do: m |> Map.values() |> Enum.each(&assert_closure_free/1)

  defp assert_closure_free(l) when is_list(l), do: Enum.each(l, &assert_closure_free/1)

  defp assert_closure_free(t) when is_tuple(t), do: t |> Tuple.to_list() |> Enum.each(&assert_closure_free/1)

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
          Workflow.Node.Loop,
          Workflow.Node.Verify,
          Workflow.Node.Judge,
          Workflow.Node.GenericFanout,
          Workflow.Node.Synthesize,
          Refine,
          EmitResult
        ] do
      assert node_mod in kinds, "expected the flagship to use #{inspect(node_mod)}"
    end
  end

  test "it uses gated refine and emits the structured refine result" do
    %Tree{nodes: nodes} = ShipFeature.__workflow__(:tree)

    assert %Refine{
             input: {:binding, :ship_report, {:node, _ship_report_address}},
             reviewers: reviewers,
             gates: gates,
             address: refine_address
           } = Enum.find(nodes, &match?(%Refine{}, &1))

    assert Enum.map(reviewers, & &1.adapter) == [:findings_v1, :findings_v1]
    assert gates.cold_read.reviewer.adapter == :findings_v1
    assert gates.cold_read.predicate == {:path_exists, ""}
    assert gates.repair.predicate == {:path_non_empty, "/coldRead/openFindings"}
    assert gates.halt.predicate == {:path_non_empty, "/roleFailures"}

    assert %EmitResult{
             binding: :reviewed_report,
             ref: {:refine, ^refine_address}
           } = List.last(nodes)
  end
end
