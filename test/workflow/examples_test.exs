defmodule Workflow.ExamplesTest do
  use ExUnit.Case, async: true

  alias Workflow.Node.Agent
  alias Workflow.Node.BudgetSlices
  alias Workflow.Node.Collect
  alias Workflow.Node.Emit
  alias Workflow.Node.EmitResult
  alias Workflow.Node.GenericFanout
  alias Workflow.Node.Judge
  alias Workflow.Node.Loop
  alias Workflow.Node.Parallel
  alias Workflow.Node.PathCount, as: FanoutPathCount
  alias Workflow.Node.Pipeline
  alias Workflow.Node.Refine
  alias Workflow.Node.Return
  alias Workflow.Node.Synthesize
  alias Workflow.Node.Until
  alias Workflow.Node.Verify
  alias Workflow.Predicate.Agree
  alias Workflow.Schema
  alias Workflow.Script
  alias Workflow.Tree

  @examples_dir Path.expand("../../examples", __DIR__)

  @manifest [
    {"change_risk_report.exs", "change-risk-report", Emit},
    {"current_diff_refine.exs", "current-diff-refine", EmitResult},
    {"storage_architecture_decision.exs", "storage-architecture-decision", Emit},
    {"flaky_test_hunt.exs", "flaky-test-hunt", Return},
    {"adr_consensus_repair.exs", "adr-consensus-repair", Return},
    {"reproduction_confidence_pipeline.exs", "reproduction-confidence-pipeline", Return},
    {"release_readiness_panel.exs", "release-readiness-panel", Emit},
    {"dependency_upgrade_swarm.exs", "dependency-upgrade-swarm", Emit},
    {"budgeted_codebase_onboarding.exs", "budgeted-codebase-onboarding", Emit},
    {"incident_triage_workbench.exs", "incident-triage-workbench", Emit}
  ]

  @core_families [
    Parallel,
    Pipeline,
    Loop,
    GenericFanout,
    Verify,
    Judge,
    Synthesize,
    Refine,
    Collect,
    Until,
    Emit,
    EmitResult,
    Return
  ]

  test "the examples directory is an exact public-loader manifest" do
    expected_files = @manifest |> Enum.map(&elem(&1, 0)) |> Enum.sort()

    actual_files =
      @examples_dir
      |> Path.join("*.exs")
      |> Path.wildcard()
      |> Enum.map(&Path.basename/1)
      |> Enum.sort()

    assert actual_files == expected_files

    loaded =
      Enum.map(@manifest, fn {file, expected_name, expected_terminal} ->
        source = File.read!(example_path(file))
        refute source =~ "/Users/", "#{file} contains a machine-specific macOS path"
        refute source =~ "/home/", "#{file} contains a machine-specific Unix home path"

        tree = load_example!(file)
        assert tree.name == expected_name
        assert List.last(tree.nodes).__struct__ == expected_terminal
        refute contains_function?(tree), "#{file} compiled to a tree containing a closure"

        tree
        |> structs()
        |> Enum.filter(&match?(%Agent{schema: schema} when not is_nil(schema), &1))
        |> Enum.each(fn %Agent{schema: schema} ->
          schema
          |> Schema.to_map()
          |> assert_string_keyed_schema!(file)
        end)

        tree
      end)

    names = Enum.map(loaded, & &1.name)
    assert length(Enum.uniq(names)) == length(names)
  end

  test "the suite exercises every core orchestration family" do
    present =
      @manifest
      |> Enum.map(fn {file, _name, _terminal} -> load_example!(file) end)
      |> structs()
      |> MapSet.new(& &1.__struct__)

    expected = MapSet.new(@core_families)

    assert MapSet.subset?(expected, present),
           "missing core example families: #{expected |> MapSet.difference(present) |> MapSet.to_list() |> inspect()}"
  end

  test "ADR consensus repairs only after an explicit loop-local panel disagrees" do
    %Tree{nodes: nodes} = load_example!("adr_consensus_repair.exs")
    assert %Loop{on_exhausted: :fail} = loop = Enum.find(nodes, &match?(%Loop{}, &1))

    fanout_index = Enum.find_index(loop.body, &match?(%GenericFanout{}, &1))
    until_index = Enum.find_index(loop.body, &match?(%Until{}, &1))

    repair_index =
      loop.body
      |> Enum.with_index()
      |> Enum.find_value(fn
        {%Agent{}, index} when index > until_index -> index
        _entry -> nil
      end)

    assert is_integer(fanout_index)
    assert is_integer(until_index)
    assert is_integer(repair_index)
    assert fanout_index < until_index
    assert until_index < repair_index

    assert %GenericFanout{
             address: fanout_address,
             bind: :checks,
             lanes: {:explicit, lanes}
           } = Enum.at(loop.body, fanout_index)

    assert length(lanes) >= 2
    assert Enum.all?(lanes, &(&1 != []))

    lane_agents = Enum.map(lanes, &List.last/1)
    assert Enum.all?(lane_agents, &match?(%Agent{}, &1))
    assert lane_agents |> Enum.map(& &1.prompt) |> Enum.uniq() |> length() == length(lanes)

    lane_schemas = Enum.map(lane_agents, fn %Agent{schema: schema} -> Schema.to_map(schema) end)
    assert lane_schemas |> Enum.uniq() |> length() == 1

    assert %Until{
             predicate: %Agree{
               binding: :checks,
               ref: {:fanout, ^fanout_address, {:loop_local, loop_address}},
               pointer: "/approved",
               literal: true,
               threshold: :all
             }
           } = Enum.at(loop.body, until_index)

    assert loop_address == loop.address
    assert %Agent{label: repair_label} = Enum.at(loop.body, repair_index)
    assert is_binary(repair_label) and repair_label != ""
  end

  test "dynamic fanout examples include bounded path and budget width expressions" do
    %Tree{nodes: dependency_nodes} = load_example!("dependency_upgrade_swarm.exs")

    assert %GenericFanout{
             width: %FanoutPathCount{
               binding: :rows,
               ref: {:node, rows_address},
               pointer: "/items",
               max: 6
             },
             bind: :checks,
             on_zero: :complete
           } = Enum.find(dependency_nodes, &match?(%GenericFanout{}, &1))

    assert Enum.any?(dependency_nodes, &match?(%Agent{address: ^rows_address}, &1))

    %Tree{nodes: onboarding_nodes} = load_example!("budgeted_codebase_onboarding.exs")

    assert %GenericFanout{
             width: %BudgetSlices{per: 4_000, max: 6},
             bind: :work,
             on_zero: :fail
           } = Enum.find(onboarding_nodes, &match?(%GenericFanout{}, &1))
  end

  test "the current-diff refinement cold-reads and repairs through a second fail-closed panel" do
    %Tree{nodes: nodes} = load_example!("current_diff_refine.exs")
    assert [first_panel, cold_read_panel] = Enum.filter(nodes, &match?(%Refine{}, &1))

    assert %Refine{
             address: first_address,
             input: {:binding, :draft, {:node, _draft_address}},
             on_non_convergence: :fail,
             max_rounds: 3
           } = first_panel

    assert %Refine{
             address: cold_read_address,
             input: {:binding, :final, {:refine, ^first_address}},
             on_non_convergence: :fail,
             max_rounds: 2,
             reviewers: cold_read_reviewers
           } = cold_read_panel

    assert Enum.map(cold_read_reviewers, & &1.name) == [:invariants, :spec]

    assert %EmitResult{binding: :improved, ref: {:refine, ^cold_read_address}} =
             List.last(nodes)
  end

  test "the reproduction pipeline is an honest set of identical, unbound replicas" do
    %Tree{nodes: nodes} = load_example!("reproduction_confidence_pipeline.exs")
    pipeline_index = Enum.find_index(nodes, &match?(%Pipeline{}, &1))
    assert is_integer(pipeline_index)

    assert %Pipeline{items: items, lanes: lanes} = pipeline = Enum.at(nodes, pipeline_index)
    assert length(items) == 3
    assert length(lanes) == length(items)
    assert Enum.all?(items, &is_binary/1)
    assert Enum.all?(lanes, &(length(&1) == 2))

    for stage_index <- 0..1 do
      stage_agents = Enum.map(lanes, &Enum.at(&1, stage_index))
      assert Enum.all?(stage_agents, &match?(%Agent{prompt: prompt} when is_binary(prompt), &1))
      assert stage_agents |> Enum.map(& &1.prompt) |> Enum.uniq() |> length() == 1
      assert stage_agents |> Enum.map(& &1.label) |> Enum.uniq() |> length() == 1
      assert Enum.all?(stage_agents, &(&1.bindings == %{}))
      assert Enum.all?(stage_agents, &String.contains?(&1.prompt, "`REPRODUCTION.md`"))
      assert Enum.all?(stage_agents, &String.contains?(&1.prompt, "sole target contract"))

      for %Agent{prompt: prompt} <- stage_agents, item <- items do
        refute String.contains?(prompt, item)
      end
    end

    assert pipeline.max_concurrency == 1
    assert [%Return{value: terminal_value}] = Enum.drop(nodes, pipeline_index + 1)
    assert is_binary(terminal_value)
  end

  defp example_path(file), do: Path.join(@examples_dir, file)

  defp load_example!(file) do
    assert {:ok, %Tree{} = tree} = Script.load_tree(example_path(file))
    tree
  end

  defp structs(%module{} = struct) when is_atom(module) do
    [struct | structs(Map.from_struct(struct))]
  end

  defp structs(map) when is_map(map), do: map |> Map.values() |> Enum.flat_map(&structs/1)
  defp structs(list) when is_list(list), do: Enum.flat_map(list, &structs/1)
  defp structs(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> Enum.flat_map(&structs/1)
  defp structs(_value), do: []

  defp assert_string_keyed_schema!(map, file) when is_map(map) do
    Enum.each(map, fn {key, value} ->
      assert is_binary(key), "#{file} has a normalized schema with non-string key #{inspect(key)}"
      assert_string_keyed_schema!(value, file)
    end)
  end

  defp assert_string_keyed_schema!(list, file) when is_list(list),
    do: Enum.each(list, &assert_string_keyed_schema!(&1, file))

  defp assert_string_keyed_schema!(_value, _file), do: :ok

  defp contains_function?(term) when is_function(term), do: true
  defp contains_function?(%_{} = struct), do: struct |> Map.from_struct() |> contains_function?()
  defp contains_function?(map) when is_map(map), do: map |> Map.values() |> Enum.any?(&contains_function?/1)
  defp contains_function?(list) when is_list(list), do: Enum.any?(list, &contains_function?/1)
  defp contains_function?(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> Enum.any?(&contains_function?/1)
  defp contains_function?(_value), do: false
end
