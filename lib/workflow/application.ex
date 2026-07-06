defmodule Workflow.Application do
  @moduledoc """
  Supervision tree. Everything a run needs is here and independently supervised —
  no run reaches for global mutable state:

    * `Workflow.Run.Registry` — unique registry; the write lease. Exactly one live
      writer may claim a `run_id`. Registry monitors the writer, so the lease is
      released the instant it dies (no heartbeat, no pid polling).
    * `Workflow.PubSub` — post-commit broadcast bus for live read surfaces.
    * `Workflow.Journal` — owner of the append-only event-log ETS table.
    * `Workflow.Run.Supervisor` — dynamic supervisor for per-run writer processes.
    * `Workflow.Web.Endpoint` — the Phoenix endpoint serving the journal-projecting
      LiveView. Started after `Workflow.PubSub` (its `pubsub_server`), and holding no
      run state of its own.
  """
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: Workflow.Run.Registry},
      {Phoenix.PubSub, name: Workflow.PubSub},
      Workflow.Journal,
      {DynamicSupervisor, name: Workflow.Run.Supervisor, strategy: :one_for_one},
      Workflow.Web.Endpoint
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Workflow.Supervisor)
  end
end
