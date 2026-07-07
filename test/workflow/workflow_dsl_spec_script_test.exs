defmodule Workflow.WorkflowDslSpecScriptTest do
  use ExUnit.Case, async: true

  alias Workflow.Node.{Agent, FanOut, Parallel, Pipeline}
  alias Workflow.Script
  alias Workflow.Tree

  @script_path Path.expand("../../.codex/workflows/workflow_dsl_spec.exs", __DIR__)

  test "migrated workflow-dsl-spec script loads as an inert workflow tree" do
    assert {:ok, %Tree{name: "workflow-dsl-spec", nodes: nodes} = tree} =
             Script.load_tree(@script_path)

    assert phase_names(nodes) == ["Ground truth", "Draft", "Converge", "Finalize"]
    refute contains_function?(tree)
  end

  test "migrated workflow preserves the Claude worker prompt contracts" do
    assert {:ok, %Tree{} = tree} = Script.load_tree(@script_path)

    prompts = tree |> agent_prompts() |> Enum.join("\n---PROMPT---\n")

    assert prompts =~ ~s|Extract GROUND TRUTH for the "spec-structure" area|
    assert prompts =~ "SURGICAL EDIT — DO NOT REWRITE SPEC.md"
    assert prompts =~ "LENS: NON-DESTRUCTIVENESS (the safety guard)"
    assert prompts =~ "Resolve these final cold-read defects with TARGETED edits to §10 only"
    assert prompts =~ "Finalize the SPEC.md §10 insertion for HUMAN REVIEW — do NOT commit anything"
  end

  defp phase_names(nodes) do
    nodes
    |> Enum.filter(&match?(%Workflow.Node.Phase{}, &1))
    |> Enum.map(& &1.name)
  end

  defp agent_prompts(%Tree{nodes: nodes}), do: agent_prompts(nodes)

  defp agent_prompts(nodes) when is_list(nodes),
    do: nodes |> Enum.flat_map(&agent_prompts/1)

  defp agent_prompts(%Agent{prompt: prompt}), do: [prompt]

  defp agent_prompts(%Parallel{branches: branches}), do: agent_prompts(branches)

  defp agent_prompts(%Pipeline{lanes: lanes}) do
    lanes
    |> List.flatten()
    |> agent_prompts()
  end

  defp agent_prompts(%FanOut{body: body}), do: agent_prompts(body)
  defp agent_prompts(_node), do: []

  defp contains_function?(term) when is_function(term), do: true
  defp contains_function?(%_{} = s), do: s |> Map.from_struct() |> contains_function?()

  defp contains_function?(m) when is_map(m),
    do: m |> Map.values() |> Enum.any?(&contains_function?/1)

  defp contains_function?(l) when is_list(l), do: Enum.any?(l, &contains_function?/1)

  defp contains_function?(t) when is_tuple(t),
    do: t |> Tuple.to_list() |> Enum.any?(&contains_function?/1)

  defp contains_function?(_), do: false
end
