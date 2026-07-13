defmodule Workflow.Web.SchedulerWorkflowController do
  @moduledoc "Workflow-facing scheduler API endpoints."

  use Phoenix.Controller, formats: [:json]

  alias Workflow.Scheduler
  alias Workflow.Scheduler.Validation
  alias Workflow.Web.SchedulerAPI

  def validate(%{body_params: body_params} = conn, _params) do
    case Scheduler.validate_workflow(body_params) do
      {:ok, validation} -> SchedulerAPI.ok(conn, Validation.to_map(validation))
      {:error, error} -> SchedulerAPI.error(conn, error)
    end
  end
end
