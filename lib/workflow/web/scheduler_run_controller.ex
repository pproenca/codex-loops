defmodule Workflow.Web.SchedulerRunController do
  @moduledoc "Run lifecycle endpoints for the scheduler API."

  use Phoenix.Controller, formats: [:json]

  alias Workflow.Scheduler
  alias Workflow.Scheduler.{RunEventsProjection, RunProjection, RunStart}
  alias Workflow.Web.SchedulerAPI

  def create(conn, params) do
    case Scheduler.start_run(params) do
      {:ok, start} -> SchedulerAPI.ok(conn, RunStart.to_map(start))
      {:error, error} -> SchedulerAPI.error(conn, error)
    end
  end

  def resume(conn, %{"id" => id} = params) do
    case Scheduler.resume_run(id, Map.delete(params, "id")) do
      {:ok, start} -> SchedulerAPI.ok(conn, RunStart.to_map(start))
      {:error, error} -> SchedulerAPI.error(conn, error)
    end
  end

  def show(conn, %{"id" => id}) do
    case Scheduler.get_run(id) do
      {:ok, projection} -> SchedulerAPI.ok(conn, RunProjection.to_map(projection))
      {:error, error} -> SchedulerAPI.error(conn, error)
    end
  end

  def events(conn, %{"id" => id}) do
    case Scheduler.get_run_events(id) do
      {:ok, projection} -> SchedulerAPI.ok(conn, RunEventsProjection.to_map(projection))
      {:error, error} -> SchedulerAPI.error(conn, error)
    end
  end
end
