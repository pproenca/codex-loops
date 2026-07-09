defmodule Workflow.Application do
  @moduledoc """
  Supervision tree. Everything a run needs is here and independently supervised —
  no run reaches for global mutable state:

    * `Workflow.Run.Registry` — unique registry; the write lease. Exactly one live
      writer may claim a `run_id`. Registry monitors the writer, so the lease is
      released the instant it dies (no heartbeat, no pid polling).
    * `Workflow.PubSub` — realtime run stream and post-commit broadcast bus for
      live read surfaces.
    * `Workflow.Journal` — owner of the append-only event-log ETS table, and a
      subscriber that persists provider activity streamed out of band.
    * `Workflow.TaskSupervisor` — supervised, unlinked worker tasks for
      failure-isolated concurrent regions such as `refine` reviewer panels.
    * `Workflow.Run.Supervisor` — dynamic supervisor for per-run writer processes.
    * `Workflow.Web.Endpoint` — the Phoenix endpoint serving the scheduler-snapshot
      LiveView. Started after `Workflow.PubSub` (its `pubsub_server`), and holding no
      run state of its own.
  """
  use Application

  alias Workflow.MCP.BurritoEnvironment

  @impl true
  def start(_type, _args) do
    if mcp_entrypoint?() do
      start_mcp()
    else
      start_scheduler()
    end
  end

  defp start_scheduler do
    children = [
      {Registry, keys: :unique, name: Workflow.Run.Registry},
      {Phoenix.PubSub, name: Workflow.PubSub},
      Workflow.Journal,
      {Task.Supervisor, name: Workflow.TaskSupervisor},
      {DynamicSupervisor, name: Workflow.Run.Supervisor, strategy: :one_for_one},
      Workflow.Web.Endpoint
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Workflow.Supervisor)
  end

  defp start_mcp do
    children = [
      Workflow.MCP.ApplicationEntrypoint
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Workflow.Supervisor)
  end

  defp mcp_entrypoint? do
    BurritoEnvironment.mcp_entrypoint?()
  end
end
