defmodule Workflow.Catalog.AdversarialVerify do
  @moduledoc """
  Catalog workflow: submit a finding to a **perspective-diverse** panel and let it
  survive only when a majority of independent lenses confirm it. Each lens votes
  from its own vantage (correctness, security, reproducibility); survival is a pure
  fold of the journaled verdicts against the threshold, so it is deterministic and
  resumable.
  """
  use Workflow

  workflow "adversarial-verify" do
    verify("the reported bug reproduces on main",
      lenses: [:correctness, :security, :repro],
      threshold: :majority
    )

    return(:done)
  end
end
