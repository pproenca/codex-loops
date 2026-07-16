defmodule Workflow.StaffLevelElixirAdversarialScanScriptTest do
  use ExUnit.Case, async: true

  alias Workflow.Node.Agent
  alias Workflow.Node.Emit
  alias Workflow.Node.GenericFanout
  alias Workflow.Script
  alias Workflow.Tree

  @script_path Path.expand("../../.codex/workflows/staff_level_elixir_adversarial_scan.exs", __DIR__)

  test "script compiles to an inert scout, diverse finder barrier, adjudicator, and critic" do
    assert {:ok, %Tree{name: "staff-level-elixir-adversarial-scan", nodes: nodes} = tree} =
             Script.load_tree(@script_path)

    assert phase_names(nodes) == ["Scope", "Find", "Adjudicate", "Completeness"]
    assert %Emit{} = List.last(nodes)
    refute contains_function?(tree)

    assert %GenericFanout{
             bind: :work,
             max_concurrency: 5,
             lanes: {:explicit, lanes}
           } = Enum.find(nodes, &match?(%GenericFanout{}, &1))

    assert length(lanes) == 5
    assert Enum.all?(lanes, &(length(&1) == 1))

    finder_agents = Enum.map(lanes, &List.first/1)

    assert Enum.map(finder_agents, & &1.label) == [
             "find:otp-failure",
             "find:concurrency",
             "find:data-idioms",
             "find:ecto-boundary",
             "find:phoenix-completeness"
           ]

    assert finder_agents |> Enum.map(& &1.prompt) |> Enum.uniq() |> length() == 5
    assert Enum.all?(finder_agents, &match?(%Agent{schema: schema} when not is_nil(schema), &1))
  end

  test "prompt contract preserves blind discovery, tri-state adjudication, and explicit coverage loss" do
    source = File.read!(@script_path)

    refute source =~ "/Users/"
    assert source =~ "do not deduplicate against imagined work by other agents"
    assert source =~ "Try to refute each candidate"
    assert source =~ "confirmed/plausible"
    assert source =~ "refuted_candidates"
    assert source =~ "unverified_candidates"
    assert source =~ "dropped_coverage"
    assert String.downcase(source) =~ "there is no top-n cap"
    assert source =~ "Do not merely rephrase or re-confirm the report"
  end

  test "top-level dataflow binds the scope and finder barrier before synthesis" do
    assert {:ok, %Tree{nodes: nodes}} = Script.load_tree(@script_path)

    assert %Agent{label: "scope:repository"} = agent_with_label(nodes, "scope:repository")

    assert %Agent{
             label: "adjudicate:candidates",
             prompt: %Workflow.Template{assigns: adjudicator_assigns}
           } = agent_with_label(nodes, "adjudicate:candidates")

    assert Enum.sort(adjudicator_assigns) == ["rows", "work"]

    assert %Agent{
             label: "critic:completeness",
             prompt: %Workflow.Template{assigns: critic_assigns}
           } = agent_with_label(nodes, "critic:completeness")

    assert Enum.sort(critic_assigns) == ["draft", "rows"]
  end

  defp phase_names(nodes) do
    nodes
    |> Enum.filter(&match?(%Workflow.Node.Phase{}, &1))
    |> Enum.map(& &1.name)
  end

  defp agent_with_label(nodes, label) do
    Enum.find(nodes, &match?(%Agent{label: ^label}, &1))
  end

  defp contains_function?(term) when is_function(term), do: true
  defp contains_function?(%_{} = struct), do: struct |> Map.from_struct() |> contains_function?()
  defp contains_function?(map) when is_map(map), do: map |> Map.values() |> Enum.any?(&contains_function?/1)
  defp contains_function?(list) when is_list(list), do: Enum.any?(list, &contains_function?/1)
  defp contains_function?(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> Enum.any?(&contains_function?/1)
  defp contains_function?(_term), do: false
end
