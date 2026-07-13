defmodule Workflow.Web.LoopbackGuard do
  @moduledoc """
  Rejects DNS-rebinding requests before they reach the shared web router.

  The packaged endpoint is deliberately loopback-only. Browser requests must
  therefore carry a loopback `Host`, and an `Origin` header, when present, must
  describe an HTTP(S) loopback origin. Non-browser clients may omit `Origin`.
  """

  @behaviour Plug

  import Plug.Conn

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    if loopback_host?(conn.host) and valid_origin_headers?(get_req_header(conn, "origin")) do
      conn
    else
      forbidden(conn)
    end
  end

  @doc """
  Phoenix socket origin callback using the same policy as routed requests.
  """
  @spec origin_allowed?(URI.t()) :: boolean()
  def origin_allowed?(%URI{} = origin), do: loopback_origin?(origin)

  defp valid_origin_headers?([]), do: true
  defp valid_origin_headers?([origin]), do: loopback_origin?(origin)
  defp valid_origin_headers?(_multiple), do: false

  defp loopback_origin?(origin) when is_binary(origin) do
    case URI.new(origin) do
      {:ok, uri} -> loopback_origin?(uri)
      {:error, _reason} -> false
    end
  end

  defp loopback_origin?(%URI{scheme: scheme, host: host, userinfo: nil, path: path, query: nil, fragment: nil})
       when scheme in ["http", "https"] and is_binary(host) and path in [nil, ""] do
    loopback_host?(host)
  end

  defp loopback_origin?(_origin), do: false

  defp loopback_host?(host) when is_binary(host) do
    case String.downcase(host) do
      "localhost" -> true
      address -> loopback_address?(address)
    end
  end

  defp loopback_host?(_host), do: false

  defp loopback_address?(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, {127, _b, _c, _d}} -> true
      {:ok, {0, 0, 0, 0, 0, 0, 0, 1}} -> true
      _not_loopback -> false
    end
  end

  defp forbidden(%Plug.Conn{request_path: "/mcp"} = conn) do
    payload = Workflow.MCP.Protocol.invalid_request("Forbidden host or origin")

    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_content_type("application/json")
    |> send_resp(403, Jason.encode!(payload))
    |> halt()
  end

  defp forbidden(conn) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_content_type("text/plain")
    |> send_resp(403, "Forbidden")
    |> halt()
  end
end
