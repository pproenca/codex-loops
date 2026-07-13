defmodule Workflow.RuntimeSupervisor do
  @moduledoc """
  Isolates the scheduler's independently restartable runtime owners.

  The root supervisor starts this process only after the journal, run registry,
  PubSub, and shared task supervisor are available. A loss of any of those
  upstream dependencies therefore replaces this whole subtree. Inside the
  subtree, `:one_for_one` keeps the Codex app-server, run supervisor, and Phoenix
  endpoint as siblings: a crash in one cannot restart either of the others.
  """
  use Supervisor

  @spec start_link(term()) :: Supervisor.on_start()
  def start_link(_init_arg), do: Supervisor.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    children = [
      Workflow.Provider.Codex.AppServer,
      {DynamicSupervisor,
       name: Workflow.Run.Supervisor, strategy: :one_for_one, max_children: Workflow.Run.max_active_runs()},
      Workflow.Web.Endpoint
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
