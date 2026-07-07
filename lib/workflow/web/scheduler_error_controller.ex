defmodule Workflow.Web.SchedulerErrorController do
  @moduledoc "Fallback responses for scheduler API requests that miss a route."

  use Phoenix.Controller, formats: [:json]

  alias Workflow.Scheduler.Error
  alias Workflow.Web.SchedulerAPI

  def not_found(conn, _params), do: SchedulerAPI.error(conn, Error.not_found())
end
