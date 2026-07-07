defmodule Workflow.Web.Router do
  @moduledoc """
  Routes the live read surface. `/runs/:run_id` mounts the journal-projecting
  LiveView for a run; `run_id` is the only routing input.
  """
  use Phoenix.Router

  import Plug.Conn
  import Phoenix.Controller
  import Phoenix.LiveView.Router

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
    match(:*, "/*path", SchedulerErrorController, :not_found)
  end

  scope "/", Workflow.Web do
    pipe_through(:browser)

    live("/runs/:run_id", RunLive)
  end
end
