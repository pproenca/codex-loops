defmodule Workflow.WorkflowDslSpecScriptTest do
  use ExUnit.Case, async: true

  alias Workflow.Node.Agent
  alias Workflow.Node.GenericFanout
  alias Workflow.Node.Loop
  alias Workflow.Node.Parallel
  alias Workflow.Node.Pipeline
  alias Workflow.Node.Refine
  alias Workflow.Node.Refine.ColdReadGate
  alias Workflow.Node.Refine.Gates
  alias Workflow.Node.Refine.HaltGate
  alias Workflow.Node.Refine.RepairGate
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
    normalized_prompts = String.replace(prompts, ~r/\s+/, " ")

    refute prompts =~ "/Users/"
    assert prompts =~ ~s|Extract GROUND TRUTH for the "spec-structure" area|
    assert prompts =~ "MAINTENANCE EDIT — DO NOT REWRITE SPEC.md"
    assert prompts =~ "§10 is the current normative home for implemented dataflow core"
    assert prompts =~ "§11 is the current authoring guide"
    assert prompts =~ "LENS: NON-DESTRUCTIVENESS (the safety guard)"
    assert prompts =~ "The adversarial refine panel found blocking defects"
    assert prompts =~ "Read the section end to end"

    refute prompts =~ "Proposed §10"
    refute prompts =~ "SPEC-DATAFLOW-PROPOSAL.md"
    refute normalized_prompts =~ "§1–§9 plus an authoring guide"
    refute normalized_prompts =~ "§1-§9 plus an authoring guide"
    refute normalized_prompts =~ "§10 insertion"
    refute normalized_prompts =~ "SURGICALLY inserting §10"

    assert prompts =~
             "Finalize the current SPEC.md maintenance pass for HUMAN REVIEW — do not commit anything"
  end

  test "migrated workflow defines stable UI labels for every agent" do
    assert {:ok, %Tree{} = tree} = Script.load_tree(@script_path)

    assert agent_labels(tree) == [
             "read:spec-structure",
             "read:dataflow",
             "draft:spec",
             "cold_read",
             "spec_completeness",
             "implementation_fidelity",
             "invariants",
             "teachability",
             "structural_lint",
             "non_destructiveness",
             "verify:final"
           ]
  end

  test "convergence loop uses refine until the panel reaches consensus" do
    assert {:ok, %Tree{nodes: nodes}} = Script.load_tree(@script_path)

    assert %Refine{
             input: {:binding, :draft, {:node, _draft_address}},
             until: :unanimous,
             max_rounds: 5,
             on_non_convergence: :accept_current,
             reviewers: reviewers,
             gates: gates
           } = Enum.find(nodes, &match?(%Refine{}, &1))

    assert Enum.map(reviewers, & &1.name) == [
             :spec_completeness,
             :implementation_fidelity,
             :invariants,
             :teachability,
             :structural_lint,
             :non_destructiveness
           ]

    assert Enum.all?(reviewers, &(&1.adapter == :findings_v1))
    assert gates.cold_read.reviewer.name == :cold_read
    assert gates.cold_read.reviewer.adapter == :findings_v1
    assert gates.cold_read.predicate == {:path_exists, ""}
    assert gates.repair.predicate == {:path_non_empty, "/coldRead/openFindings"}
    assert gates.halt.predicate == {:path_non_empty, "/roleFailures"}

    prompts = Enum.map_join(reviewers, "\n---PROMPT---\n", & &1.prompt)
    assert prompts =~ "Return approved=false with blocking findings"
    assert prompts =~ "LENS: NON-DESTRUCTIVENESS (the safety guard)"
    assert prompts =~ "§10 dataflow core is normative"
  end

  test "final cold-read is modeled as a refine gate instead of an ad-hoc bound agent" do
    assert {:ok, %Tree{} = tree} = Script.load_tree(@script_path)

    refute Enum.any?(agents(tree), &match?(%Agent{label: "revise:cold-read"}, &1))

    refute Enum.any?(
             agents(tree),
             &match?(%Agent{prompt: %Workflow.Template{assigns: ["cold_read"]}}, &1)
           )

    assert %Refine{
             gates: %Gates{
               cold_read: %ColdReadGate{} = cold_read,
               repair: %RepairGate{} = repair,
               halt: %HaltGate{} = halt
             }
           } =
             Enum.find(tree.nodes, &match?(%Refine{}, &1))

    assert cold_read.reviewer.agent.label == "cold_read"
    assert repair.agent.prompt =~ "The adversarial refine panel found blocking defects"
    assert halt.predicate == {:path_non_empty, "/roleFailures"}
  end

  defp phase_names(nodes) do
    nodes
    |> Enum.filter(&match?(%Workflow.Node.Phase{}, &1))
    |> Enum.map(& &1.name)
  end

  defp agent_prompts(%Tree{nodes: nodes}), do: agent_prompts(nodes)

  defp agent_prompts(nodes) when is_list(nodes), do: Enum.flat_map(nodes, &agent_prompts/1)

  defp agent_prompts(%Agent{prompt: prompt}), do: [prompt_text(prompt)]

  defp agent_prompts(%Parallel{branches: branches}), do: agent_prompts(branches)

  defp agent_prompts(%Pipeline{lanes: lanes}) do
    lanes
    |> List.flatten()
    |> agent_prompts()
  end

  defp agent_prompts(%GenericFanout{lanes: {:repeat, lane}}), do: agent_prompts(lane)
  defp agent_prompts(%GenericFanout{lanes: {:explicit, lanes}}), do: agent_prompts(lanes)
  defp agent_prompts(%Loop{body: body}), do: agent_prompts(body)

  defp agent_prompts(%Refine{input: {:producer, producer}, reviewers: reviewers, reviser: reviser, gates: gates}) do
    [producer, reviser | refine_gate_agents(gates)]
    |> Kernel.++(Enum.map(reviewers, & &1.agent))
    |> agent_prompts()
  end

  defp agent_prompts(%Refine{reviewers: reviewers, reviser: reviser, gates: gates}),
    do: agent_prompts([reviser | refine_gate_agents(gates)] ++ Enum.map(reviewers, & &1.agent))

  defp agent_prompts(_node), do: []

  defp prompt_text(prompt) when is_binary(prompt), do: prompt

  defp prompt_text(%Workflow.Template{segments: segments}), do: Enum.join(segments, "<template-hole>")

  defp contains_function?(term) when is_function(term), do: true
  defp contains_function?(%_{} = s), do: s |> Map.from_struct() |> contains_function?()

  defp contains_function?(m) when is_map(m), do: m |> Map.values() |> Enum.any?(&contains_function?/1)

  defp contains_function?(l) when is_list(l), do: Enum.any?(l, &contains_function?/1)

  defp contains_function?(t) when is_tuple(t), do: t |> Tuple.to_list() |> Enum.any?(&contains_function?/1)

  defp contains_function?(_), do: false

  defp agent_labels(%Tree{nodes: nodes}), do: agent_labels(nodes)

  defp agent_labels(nodes) when is_list(nodes), do: Enum.flat_map(nodes, &agent_labels/1)

  defp agent_labels(%Agent{label: nil}), do: []
  defp agent_labels(%Agent{label: label}), do: [label]
  defp agent_labels(%Parallel{branches: branches}), do: agent_labels(branches)

  defp agent_labels(%Pipeline{lanes: lanes}) do
    lanes
    |> List.flatten()
    |> agent_labels()
  end

  defp agent_labels(%GenericFanout{lanes: {:repeat, lane}}), do: agent_labels(lane)
  defp agent_labels(%GenericFanout{lanes: {:explicit, lanes}}), do: agent_labels(lanes)
  defp agent_labels(%Loop{body: body}), do: agent_labels(body)

  defp agent_labels(%Refine{input: {:producer, producer}, reviewers: reviewers, reviser: reviser, gates: gates}) do
    [producer, reviser | refine_gate_agents(gates)]
    |> Kernel.++(Enum.map(reviewers, & &1.agent))
    |> agent_labels()
  end

  defp agent_labels(%Refine{reviewers: reviewers, reviser: reviser, gates: gates}),
    do: agent_labels([reviser | refine_gate_agents(gates)] ++ Enum.map(reviewers, & &1.agent))

  defp agent_labels(_node), do: []

  defp agents(%Tree{nodes: nodes}), do: agents(nodes)

  defp agents(nodes) when is_list(nodes), do: Enum.flat_map(nodes, &agents/1)

  defp agents(%Agent{} = agent), do: [agent]
  defp agents(%Parallel{branches: branches}), do: agents(branches)

  defp agents(%Pipeline{lanes: lanes}) do
    lanes
    |> List.flatten()
    |> agents()
  end

  defp agents(%GenericFanout{lanes: {:repeat, lane}}), do: agents(lane)
  defp agents(%GenericFanout{lanes: {:explicit, lanes}}), do: agents(lanes)
  defp agents(%Loop{body: body}), do: agents(body)

  defp agents(%Refine{input: {:producer, producer}, reviewers: reviewers, reviser: reviser, gates: gates}) do
    [producer, reviser | refine_gate_agents(gates)]
    |> Kernel.++(Enum.map(reviewers, & &1.agent))
    |> agents()
  end

  defp agents(%Refine{reviewers: reviewers, reviser: reviser, gates: gates}),
    do: agents([reviser | refine_gate_agents(gates)] ++ Enum.map(reviewers, & &1.agent))

  defp agents(_node), do: []

  defp refine_gate_agents(gates) do
    gates
    |> then(&[&1.cold_read, &1.repair, &1.halt])
    |> Enum.flat_map(fn
      nil -> []
      %{reviewer: %{agent: agent}} -> [agent]
      %{agent: agent} -> [agent]
      _gate -> []
    end)
  end
end
