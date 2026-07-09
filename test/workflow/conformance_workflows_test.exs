defmodule Workflow.ConformanceWorkflowsTest do
  use ExUnit.Case, async: true

  alias Workflow.Node.Emit
  alias Workflow.Node.EmitResult
  alias Workflow.Node.GenericFanout
  alias Workflow.Node.Return
  alias Workflow.Script

  @workflow_dir Path.expand("../../.codex/workflows", __DIR__)

  test "packaged conformance workflows load through the public script gate" do
    assert {:ok, core} = Script.load_tree(Path.join(@workflow_dir, "conformance_core.exs"))
    assert {:ok, dataflow} = Script.load_tree(Path.join(@workflow_dir, "conformance_dataflow.exs"))
    assert {:ok, refine} = Script.load_tree(Path.join(@workflow_dir, "conformance_refine.exs"))

    assert core.name == "conformance-core"
    assert dataflow.name == "conformance-dataflow"
    assert refine.name == "conformance-refine"

    assert match?(%Return{}, List.last(core.nodes))
    assert match?(%Emit{}, List.last(dataflow.nodes))
    assert match?(%EmitResult{}, List.last(refine.nodes))

    assert Enum.any?(core.nodes, &match?(%GenericFanout{repeated: false}, &1))
  end
end
