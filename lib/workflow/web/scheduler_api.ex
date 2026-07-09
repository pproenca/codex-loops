defmodule Workflow.Web.SchedulerAPI do
  @moduledoc "JSON response envelopes for the scheduler API."

  import Phoenix.Controller, only: [json: 2]
  import Plug.Conn

  alias Workflow.Scheduler.Error

  @api_version "scheduler.v1"

  @spec ok(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def ok(conn, data) do
    json(conn, %{
      api_version: @api_version,
      data: data
    })
  end

  @spec error(Plug.Conn.t(), Error.t()) :: Plug.Conn.t()
  def error(conn, %Error{} = error) do
    conn
    |> put_status(error.status)
    |> json(%{
      api_version: @api_version,
      error: %{
        code: error.code,
        message: error.message,
        details: error.details
      }
    })
  end
end
