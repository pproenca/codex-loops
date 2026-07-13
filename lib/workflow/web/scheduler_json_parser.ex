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

  @body_methods ~w(POST PUT PATCH DELETE)
  @max_body_bytes 65_536
  @parser_opts Plug.Parsers.init(
                 parsers: [:json],
                 pass: [],
                 length: @max_body_bytes,
                 json_decoder: Phoenix.json_library()
               )

  def init(opts), do: opts

  def call(%{method: method} = conn, _opts) when method in @body_methods do
    case get_req_header(conn, "content-type") do
      [] -> reject(conn, Error.unsupported_media_type(nil))
      _headers -> parse(conn)
    end
  end

  def call(conn, _opts), do: parse(conn)

  defp parse(conn) do
    Plug.Parsers.call(conn, @parser_opts)
  rescue
    Plug.Parsers.ParseError ->
      reject(conn, Error.malformed_json())

    Plug.Parsers.BadEncodingError ->
      reject(conn, Error.malformed_json())

    error in Plug.Parsers.UnsupportedMediaTypeError ->
      reject(conn, Error.unsupported_media_type(error.media_type))

    Plug.Parsers.RequestTooLargeError ->
      reject(conn, Error.request_too_large(@max_body_bytes))
  end

  defp reject(conn, error), do: conn |> SchedulerAPI.error(error) |> halt()
end
