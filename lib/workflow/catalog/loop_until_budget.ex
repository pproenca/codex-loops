defmodule Workflow.Catalog.LoopUntilBudget do
  @moduledoc """
  Catalog workflow: loop a unit of work **until the budget runs low**. Each
  iteration spends provider budget, so the ledger's `remaining` falls monotonically
  and the loop provably terminates once it drops to `reserve`.
  """
  use Workflow

  workflow "loop-until-budget" do
    while_budget reserve: 8 do
      agent("do one unit of work")
    end

    return(:done)
  end
end
