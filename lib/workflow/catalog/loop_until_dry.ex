defmodule Workflow.Catalog.LoopUntilDry do
  @moduledoc """
  Catalog workflow: keep harvesting items and accumulating them with the generic
  loop core **until the well runs dry** — two consecutive rounds that surface
  nothing new (deduped by `:id`).
  The accumulator is a declared reduction rebuilt from the journal, so a crash mid
  loop resumes with no lost or duplicated items.
  """
  use Workflow

  workflow "loop-until-dry" do
    loop max_iterations: 1000, until: dry(rounds: 2, seen_by: [:id]) do
      agent("find more items", schema: %{"type" => "array"})
      collect(into: :items)
    end

    return(:done)
  end
end
