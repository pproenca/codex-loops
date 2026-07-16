defmodule Workflow.PlanIdentity do
  @moduledoc """
  Canonical internal identities for inert plans and journaled run inputs.

  The digest domains are versioned independently. Deterministic ETF is suitable
  here because both values are scheduler-owned Elixir data, not an interchange
  format. Changing their canonical representation requires a new domain tag.
  """

  alias Workflow.Tree

  @spec fingerprint(Tree.t()) :: String.t()
  def fingerprint(%Tree{} = tree), do: digest("codex-loops-plan/v1", tree)

  @spec input_digest(term()) :: String.t()
  def input_digest(args), do: digest("codex-loops-input/v1", args)

  defp digest(domain, value) do
    payload = :erlang.term_to_binary({domain, value}, [:deterministic])

    :sha256
    |> :crypto.hash(payload)
    |> Base.encode16(case: :lower)
  end
end
