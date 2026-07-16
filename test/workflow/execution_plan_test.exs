defmodule Workflow.ExecutionPlanTest do
  use ExUnit.Case, async: false

  alias Workflow.Execution.Plan

  test "builds one flat, bounded DAG with stable references and no Reactor retries" do
    plan = Plan.build(["one", "two", "three"], & &1, self(), 1_000)

    assert plan.return == :order
    assert length(plan.steps) == 7

    assert Enum.all?(plan.steps, fn step ->
             step.ref == step.name and step.max_retries == 0
           end)

    assert Enum.all?(plan.steps, fn step ->
             step.name == :order or
               step.name == {:workflow_worker, elem(step.name, 1)} or
               step.name == {:workflow_collect, elem(step.name, 1)}
           end)

    assert plan.steps
           |> Enum.flat_map(& &1.arguments)
           |> Enum.map(& &1.name)
           |> Enum.all?(&(&1 in [:item, :prior, :results]))

    assert plan.steps
           |> Enum.filter(&match?({:workflow_worker, _}, &1.name))
           |> Enum.all?(& &1.async?)

    assert plan.steps
           |> Enum.filter(&match?({:workflow_collect, _}, &1.name))
           |> Enum.all?(&(not &1.async?))
  end

  test "workflow-authored values do not become plan atoms" do
    _warm = Plan.build(["warm"], & &1, self(), 1_000)
    before = :erlang.system_info(:atom_count)

    for index <- 1..200 do
      value = "external-workflow-name-#{index}-#{System.unique_integer([:positive])}"
      _plan = Plan.build([value], & &1, self(), 1_000)
    end

    assert :erlang.system_info(:atom_count) == before
  end

  test "static frontiers wider than dynamic fanout remain compatible" do
    plan = Plan.build(Enum.to_list(1..65), & &1, self(), 1_000)

    assert plan.return == :order
    assert Enum.count(plan.steps, &match?({:workflow_worker, _}, &1.name)) == 8
    assert length(plan.steps) == 17
  end
end
