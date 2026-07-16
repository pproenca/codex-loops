defmodule Workflow.Execution.Step.Order do
  @moduledoc false
  use Reactor.Step

  @impl true
  def run(%{results: results}, _context, _opts) do
    ordered = results |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(&elem(&1, 1))
    {:ok, ordered}
  end
end
