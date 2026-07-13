defmodule Workflow.Web.LoopbackGuardTest do
  use ExUnit.Case, async: true

  import Phoenix.ConnTest
  import Plug.Conn, only: [prepend_req_headers: 2, put_req_header: 3]

  @endpoint Workflow.Web.Endpoint

  test "API and LiveView accept loopback hosts with absent or loopback origins" do
    assert %{"data" => %{"status" => "ok"}} =
             loopback_conn()
             |> get("/api/health")
             |> json_response(200)

    assert "127.0.0.2"
           |> loopback_conn()
           |> put_req_header("origin", "http://localhost:47125")
           |> get("/runs/missing")
           |> response(200) =~ "Run unavailable"

    assert "::1"
           |> loopback_conn()
           |> put_req_header("origin", "http://[::1]:47125")
           |> get("/api/health")
           |> json_response(200)
           |> get_in(["data", "status"]) == "ok"
  end

  test "one guard rejects non-loopback Host values on API, MCP, and LiveView" do
    for path <- ["/api/health", "/mcp", "/runs/missing"] do
      conn = get(host_conn("attacker.example"), path)

      if path == "/mcp" do
        assert %{"error" => %{"code" => -32_600}} = json_response(conn, 403)
      else
        assert response(conn, 403) == "Forbidden"
      end
    end
  end

  test "present non-loopback, malformed, path-bearing, and duplicate Origins are rejected" do
    origins = [
      "https://attacker.example",
      "http://[::1",
      "http://localhost/path"
    ]

    for origin <- origins do
      conn =
        loopback_conn()
        |> put_req_header("origin", origin)
        |> get("/api/health")

      assert response(conn, 403) == "Forbidden"
    end

    conn =
      loopback_conn()
      |> prepend_req_headers([
        {"origin", "http://localhost:47125"},
        {"origin", "http://127.0.0.1:47125"}
      ])
      |> get("/api/health")

    assert response(conn, 403) == "Forbidden"
  end

  test "wildcard and unspecified addresses are not request hosts" do
    for host <- ["0.0.0.0", "::", "127.0.0.1.attacker.example", "localhost."] do
      conn = get(host_conn(host), "/api/health")
      assert response(conn, 403) == "Forbidden"
    end
  end

  defp loopback_conn(host \\ "localhost"), do: host_conn(host)

  defp host_conn(host) do
    %{build_conn() | host: host, port: 47_125}
  end
end
