defmodule Workflow.Web.SchedulerRunController do
  @moduledoc """
  Placeholder run lifecycle endpoint.

  Starting runs is intentionally out of scope for this slice; the controller still
  goes through the scheduler context so the HTTP error envelope is established now.
  """

  use Phoenix.Controller, formats: [:json]

  alias Workflow.Scheduler
  alias Workflow.Web.SchedulerAPI

  def create(conn, params) do
    case Scheduler.start_run(params) do
      {:error, error} -> SchedulerAPI.error(conn, error)
    end
  end
end
