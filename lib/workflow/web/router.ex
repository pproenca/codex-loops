defmodule Workflow.Web.Router do
  @moduledoc """
  Routes the live read surface. `/runs/:run_id` mounts the scheduler-snapshot
  LiveView for a run; `run_id` is the only routing input.
  """
  use Phoenix.Router

  import Phoenix.Controller
  import Phoenix.LiveView.Router
  import Plug.Conn

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  pipeline :api do
    plug(:accepts, ["json"])
    plug(Workflow.Web.SchedulerJSONParser)
  end

  scope "/api", Workflow.Web do
    pipe_through(:api)

    get("/health", SchedulerHealthController, :show)
    post("/runs", SchedulerRunController, :create)
    get("/runs/:id/events", SchedulerRunController, :events)
    post("/runs/:id/resume", SchedulerRunController, :resume)
    get("/runs/:id", SchedulerRunController, :show)
    post("/workflows/validate", SchedulerWorkflowController, :validate)
    match(:*, "/*path", SchedulerErrorController, :not_found)
  end

  scope "/", Workflow.Web do
    pipe_through(:browser)

    live("/runs/:run_id", RunLive)
  end
end
