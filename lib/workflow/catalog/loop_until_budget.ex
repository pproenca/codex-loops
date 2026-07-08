defmodule Workflow.Catalog.LoopUntilBudget do
  @moduledoc """
  Catalog workflow: loop a unit of work with the generic loop core **until the
  budget runs low**. Each iteration spends provider budget, so the ledger's
  `remaining` falls monotonically and the loop provably terminates once it drops
  to the reserve.
  """
  use Workflow

  workflow "loop-until-budget" do
    loop max_iterations: 1000, until: budget_remaining() <= 8 do
      agent("do one unit of work")
    end

    return(:done)
  end
end
