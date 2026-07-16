defmodule Workflow.Execution.Step.Collect do
  @moduledoc false
  use Reactor.Step

  @impl true
  def run(%{prior: prior, item: items}, _context, _opts) do
    {:ok, prior ++ items}
  end
end
