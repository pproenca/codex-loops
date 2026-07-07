defmodule Workflow.Web.SchedulerHealthController do
  @moduledoc "Health endpoint for MCP lifecycle adapters."

  use Phoenix.Controller, formats: [:json]

  alias Workflow.Scheduler
  alias Workflow.Scheduler.Health
  alias Workflow.Web.SchedulerAPI

  def show(conn, _params) do
    case Scheduler.health() do
      {:ok, health} -> SchedulerAPI.ok(conn, Health.to_map(health))
      {:error, error} -> SchedulerAPI.error(conn, error)
    end
  end
end
