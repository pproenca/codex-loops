defmodule Workflow.Application do
  @moduledoc """
  Supervision tree. Root child order is the dependency recovery plan: later
  children restart with earlier dependencies under `:rest_for_one`.

    * `Workflow.Journal` — owner of the append-only SQLite event log and the first
      dependency in the restart chain.
    * `Workflow.Run.Registry` — unique registry; the write lease. Exactly one live
      writer may claim a `run_id`. Registry monitors the writer, so the lease is
      released the instant it dies (no heartbeat, no pid polling).
    * `Workflow.PubSub` — post-commit refresh notifications for live read surfaces;
      the journal, not PubSub, remains authoritative.
    * `Workflow.TaskSupervisor` — supervised, unlinked worker tasks for
      failure-isolated concurrent regions such as `refine` reviewer panels. It
      remains upstream because writers and app-server binding verification use it.
    * `Workflow.RuntimeSupervisor` — a `:one_for_one` isolation boundary around
      the Codex app-server owner, per-run writer supervisor, and Phoenix endpoint.
      A sibling crash stays local, while replacement of any root dependency
      terminates and rebuilds the complete downstream runtime.
  """
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Workflow.Journal,
      {Registry, keys: :unique, name: Workflow.Run.Registry},
      {Phoenix.PubSub, name: Workflow.PubSub},
      {Task.Supervisor, name: Workflow.TaskSupervisor},
      Workflow.RuntimeSupervisor
    ]

    Supervisor.start_link(children, strategy: :rest_for_one, name: Workflow.Supervisor)
  end
end
