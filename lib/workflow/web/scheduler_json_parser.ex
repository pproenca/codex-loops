defmodule Workflow.Web.SchedulerJSONParser do
  @moduledoc """
  JSON body parser for scheduler API requests.

  Parser failures happen before a controller action can call the scheduler context,
  so this plug turns malformed JSON into the same scheduler error envelope clients
  get from controller-backed expected failures.
  """

  import Plug.Conn

  alias Workflow.Scheduler.Error
  alias Workflow.Web.SchedulerAPI

  @parser_opts Plug.Parsers.init(
                 parsers: [:json],
                 pass: ["*/*"],
                 json_decoder: Phoenix.json_library()
               )

  def init(opts), do: opts

  def call(conn, _opts) do
    Plug.Parsers.call(conn, @parser_opts)
  rescue
    Plug.Parsers.ParseError ->
      conn
      |> SchedulerAPI.error(Error.malformed_json())
      |> halt()
  end
end
