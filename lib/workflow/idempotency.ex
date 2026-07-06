defmodule Workflow.Idempotency do
  @moduledoc """
  Exactly-once resolution for paid effects. Reuse is decided purely from the
  journal: if an agent turn for `(node_path, iteration)` was already committed, its
  result and usage are replayed instead of calling the provider again. On resume
  this is what guarantees a paid effect is never re-run.
  """

  @spec committed_effect([Workflow.Event.t()], Workflow.Node.address(), non_neg_integer()) ::
          {:ok, Workflow.Provider.result(), Workflow.Provider.Usage.t()} | :none
  def committed_effect(events, node_path, iteration) do
    Enum.find_value(events, :none, fn
      %{type: :agent_committed, payload: %{address: ^node_path, iteration: ^iteration} = payload} ->
        {:ok, payload.result, payload.usage}

      _event ->
        false
    end)
  end
end
