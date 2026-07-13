defmodule Workflow.Web.SchedulerRunController do
  @moduledoc "Run lifecycle endpoints for the scheduler API."

  use Phoenix.Controller, formats: [:json]

  alias Workflow.Scheduler
  alias Workflow.Scheduler.RunEventsProjection
  alias Workflow.Scheduler.RunProjection
  alias Workflow.Scheduler.RunStart
  alias Workflow.Web.SchedulerAPI

  def create(%{body_params: body_params} = conn, _params) do
    case Scheduler.start_run(body_params) do
      {:ok, start} -> SchedulerAPI.ok(conn, RunStart.to_map(start))
      {:error, error} -> SchedulerAPI.error(conn, error)
    end
  end

  def resume(%{body_params: body_params, path_params: %{"id" => id}} = conn, _params) do
    case Scheduler.resume_run(id, body_params) do
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
