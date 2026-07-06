defmodule Workflow.Catalog.JudgePanel do
  @moduledoc """
  Catalog workflow: score a fixed slate of candidate plans along two criteria, pick
  the highest total, then synthesize a write-up. Every score is a journaled,
  fail-closed agent turn; the winner is a pure fold of those scores, and the
  synthesis reuses the ordinary exactly-once agent path — so the whole panel is
  deterministic and resumable.
  """
  use Workflow

  workflow "judge-panel" do
    judge(["plan A", "plan B", "plan C"], by: [:feasibility, :impact], pick: :max_score)
    synthesize(["plan A", "plan B", "plan C"], "Write up the winning plan.")
    return(:done)
  end
end
