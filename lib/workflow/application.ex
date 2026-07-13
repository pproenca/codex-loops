defmodule Workflow.Application do
  @moduledoc """
  Supervision tree. Child order is the recovery plan: later children depend on
  earlier children and restart with them under `:rest_for_one`.

    * `Workflow.Journal` — owner of the append-only SQLite event log and the first
      dependency in the restart chain.
    * `Workflow.Run.Registry` — unique registry; the write lease. Exactly one live
      writer may claim a `run_id`. Registry monitors the writer, so the lease is
      released the instant it dies (no heartbeat, no pid polling).
    * `Workflow.PubSub` — post-commit refresh notifications for live read surfaces;
      the journal, not PubSub, remains authoritative.
    * `Workflow.TaskSupervisor` — supervised, unlinked worker tasks for
      failure-isolated concurrent regions such as `refine` reviewer panels.
    * `Workflow.Run.Supervisor` — dynamic supervisor for per-run writer processes.
    * `Workflow.Web.Endpoint` — the Phoenix endpoint serving the scheduler-snapshot
      LiveView. It starts after its dependencies and holds no run state of its own.
  """
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Workflow.Journal,
      {Registry, keys: :unique, name: Workflow.Run.Registry},
      {Phoenix.PubSub, name: Workflow.PubSub},
      {Task.Supervisor, name: Workflow.TaskSupervisor},
      {DynamicSupervisor, name: Workflow.Run.Supervisor, strategy: :one_for_one},
      Workflow.Web.Endpoint
    ]

    Supervisor.start_link(children, strategy: :rest_for_one, name: Workflow.Supervisor)
  end
end
