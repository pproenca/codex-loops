defmodule Workflow.Web.MCPController do
  @moduledoc """
  Streamable HTTP transport for the scheduler-owned MCP surface.

  This is intentionally the stateless, JSON-response form of the transport:
  there is no SSE channel, session identifier, or process per MCP client.
  """

  use Phoenix.Controller, formats: [:json]

  import Plug.Conn

  alias Workflow.MCP.Protocol

  @max_body_bytes 1_048_576
  @read_timeout 5_000

  @spec handle(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def handle(conn, _params), do: route(conn)

  defp route(%Plug.Conn{method: "POST"} = conn), do: handle_post(conn)
  defp route(%Plug.Conn{} = conn), do: method_not_allowed(conn)

  defp handle_post(conn) do
    with :ok <- require_json_content_type(conn),
         :ok <- require_streamable_http_accept(conn) do
      read_message(conn)
    else
      {:error, :unsupported_media_type} ->
        send_json(conn, 415, Protocol.invalid_request("Content-Type must be application/json"))

      {:error, :not_acceptable} ->
        send_json(
          conn,
          406,
          Protocol.invalid_request("Accept must include application/json and text/event-stream")
        )
    end
  end

  defp read_message(conn) do
    case read_body(conn,
           length: @max_body_bytes,
           read_length: 64_000,
           read_timeout: @read_timeout
         ) do
      {:ok, body, conn} -> decode_message(conn, body)
      {:more, _partial, conn} -> send_json(conn, 413, Protocol.invalid_request("Request body is too large"))
      {:error, _reason} -> send_json(conn, 400, Protocol.parse_error())
    end
  end

  defp decode_message(conn, body) do
    case Jason.decode(body) do
      {:ok, message} -> dispatch_message(conn, message)
      {:error, _error} -> send_json(conn, 400, Protocol.parse_error())
    end
  end

  defp dispatch_message(conn, message) do
    opts = [
      protocol_version: protocol_version(conn),
      base_url: Workflow.Web.Endpoint.url()
    ]

    case Protocol.handle(message, opts) do
      {:reply, response} -> send_json(conn, 200, response)
      :accepted -> send_resp(conn, 202, "")
      {:bad_request, response} -> send_json(conn, 400, response)
    end
  end

  defp require_json_content_type(conn) do
    case get_req_header(conn, "content-type") do
      [content_type] ->
        if media_type(content_type) == "application/json",
          do: :ok,
          else: {:error, :unsupported_media_type}

      _missing_or_multiple ->
        {:error, :unsupported_media_type}
    end
  end

  defp require_streamable_http_accept(conn) do
    accepted_ranges =
      conn
      |> get_req_header("accept")
      |> Enum.flat_map(&String.split(&1, ","))
      |> Enum.map(&accept_range/1)

    if acceptable?(accepted_ranges, "application/json") and
         acceptable?(accepted_ranges, "text/event-stream"),
       do: :ok,
       else: {:error, :not_acceptable}
  end

  defp acceptable?(ranges, media_type) do
    Enum.any?(ranges, fn
      {^media_type, quality} when quality > 0 -> true
      _range -> false
    end)
  end

  defp accept_range(value) do
    [type | params] = String.split(value, ";")

    case accept_quality(params) do
      {:ok, quality} -> {type |> String.trim() |> String.downcase(), quality}
      :error -> :invalid
    end
  end

  defp accept_quality(params) do
    params
    |> Enum.reduce_while({:ok, nil}, fn param, {:ok, quality} ->
      case String.split(param, "=", parts: 2) do
        [name, value] ->
          if name |> String.trim() |> String.downcase() == "q" do
            if is_nil(quality) do
              case parse_quality(String.trim(value)) do
                {:ok, parsed} -> {:cont, {:ok, parsed}}
                :error -> {:halt, :error}
              end
            else
              {:halt, :error}
            end
          else
            {:cont, {:ok, quality}}
          end

        [name] ->
          if name |> String.trim() |> String.downcase() == "q",
            do: {:halt, :error},
            else: {:cont, {:ok, quality}}
      end
    end)
    |> case do
      {:ok, nil} -> {:ok, 1.0}
      {:ok, quality} -> {:ok, quality}
      :error -> :error
    end
  end

  defp parse_quality(value) do
    if Regex.match?(~r/\A(?:0(?:\.\d{0,3})?|1(?:\.0{0,3})?)\z/, value) do
      normalized =
        cond do
          String.ends_with?(value, ".") -> value <> "0"
          String.contains?(value, ".") -> value
          true -> value <> ".0"
        end

      case Float.parse(normalized) do
        {quality, ""} -> {:ok, quality}
        _invalid -> :error
      end
    else
      :error
    end
  end

  defp media_type(value) do
    value
    |> String.split(";", parts: 2)
    |> hd()
    |> String.trim()
    |> String.downcase()
  end

  defp protocol_version(conn) do
    case get_req_header(conn, "mcp-protocol-version") do
      [] -> nil
      [version] -> String.trim(version)
      _multiple -> "multiple"
    end
  end

  defp method_not_allowed(conn) do
    conn
    |> put_resp_header("allow", "POST")
    |> send_resp(405, "")
  end

  defp send_json(conn, status, payload) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(payload))
  end
end
