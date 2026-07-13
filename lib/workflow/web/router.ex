defmodule Workflow.Web.Router do
  @moduledoc """
  Routes the scheduler's HTTP surfaces: direct Streamable HTTP MCP at `/mcp`,
  the JSON API under `/api`, and journal-backed run LiveViews.
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

  match(:*, "/mcp", Workflow.Web.MCPController, :handle)

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
