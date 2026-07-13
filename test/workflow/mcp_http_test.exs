defmodule Workflow.MCPHTTPTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Plug.Conn, only: [get_resp_header: 2, put_req_header: 3]

  alias Workflow.Scheduler
  alias Workflow.Web.Endpoint

  @endpoint Endpoint
  @protocol_version "2025-11-25"

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "codex_loops_mcp_http_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    %{root: root}
  end

  test "POST initializes without an Origin and permits a loopback Origin" do
    request = initialize_request(1)

    conn = post_mcp(request)
    assert %{"result" => %{"protocolVersion" => @protocol_version}} = json_response(conn, 200)
    assert get_resp_header(conn, "mcp-session-id") == []

    conn = post_mcp(request, "http://localhost:47125")
    assert %{"result" => %{"serverInfo" => %{"name" => "codex-loops"}}} = json_response(conn, 200)
  end

  test "hostile Origins are forbidden before protocol dispatch" do
    conn = 1 |> initialize_request() |> post_mcp("https://attacker.example")

    assert %{"error" => %{"code" => -32_600, "message" => "Forbidden host or origin"}} =
             json_response(conn, 403)
  end

  test "notifications return 202 while GET and DELETE decline SSE sessions" do
    notification = %{
      "jsonrpc" => "2.0",
      "method" => "notifications/initialized",
      "params" => %{}
    }

    conn = post_mcp(notification, nil, @protocol_version)
    assert response(conn, 202) == ""

    conn = post_mcp(%{notification | "params" => "malformed"}, nil, @protocol_version)
    assert response(conn, 202) == ""

    for conn <- [get(loopback_conn(), "/mcp"), delete(loopback_conn(), "/mcp")] do
      assert response(conn, 405) == ""
      assert get_resp_header(conn, "allow") == ["POST"]
    end
  end

  test "the HTTP boundary enforces media negotiation, protocol versions, and body size" do
    body = Jason.encode!(initialize_request(1))

    conn =
      loopback_conn()
      |> put_req_header("content-type", "text/plain")
      |> put_req_header("accept", "application/json, text/event-stream")
      |> post("/mcp", body)

    assert json_response(conn, 415)["error"]["message"] =~ "Content-Type"

    conn =
      loopback_conn()
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "application/json")
      |> post("/mcp", body)

    assert json_response(conn, 406)["error"]["message"] =~ "Accept"

    conn = post_mcp(%{"jsonrpc" => "2.0", "id" => 2, "method" => "ping"}, nil, "2024-11-05")
    version_error = json_response(conn, 400)
    assert version_error["error"]["message"] =~ "Unsupported MCP protocol version"
    refute Map.has_key?(version_error, "id")

    oversized =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => 3,
        "method" => "tools/call",
        "params" => %{"name" => "workflow_validate", "arguments" => %{"padding" => String.duplicate("x", 1_048_576)}}
      })

    conn = raw_post_mcp(oversized, @protocol_version)
    assert json_response(conn, 413)["error"]["message"] =~ "too large"
  end

  test "Accept quality values must permit both Streamable HTTP response types" do
    body = Jason.encode!(initialize_request(1))

    for accept <- [
          "application/json;q=0, text/event-stream",
          "application/json, text/event-stream; q=0.000",
          "application/json; q=bogus, text/event-stream"
        ] do
      conn =
        loopback_conn()
        |> put_req_header("content-type", "application/json")
        |> put_req_header("accept", accept)
        |> post("/mcp", body)

      assert json_response(conn, 406)["error"]["message"] =~ "Accept"
    end

    conn =
      loopback_conn()
      |> put_req_header("content-type", "application/json")
      |> put_req_header(
        "accept",
        "application/json; charset=utf-8; q=0.001, text/event-stream; q=1.000"
      )
      |> post("/mcp", body)

    assert %{"result" => %{"protocolVersion" => @protocol_version}} = json_response(conn, 200)
  end

  test "2025-03-26 accepts aggregate batches and newer versions reject them" do
    batch = [
      %{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"},
      %{"jsonrpc" => "2.0", "method" => "notifications/initialized"},
      %{"jsonrpc" => "2.0", "id" => 9, "result" => %{}}
    ]

    conn = post_mcp(batch)
    assert [%{"jsonrpc" => "2.0", "id" => 1, "result" => %{}}] = json_response(conn, 200)

    conn = post_mcp(tl(batch), nil, "2025-03-26")
    assert response(conn, 202) == ""

    conn = post_mcp([], nil, "2025-03-26")
    empty_error = json_response(conn, 400)
    assert empty_error["error"]["message"] =~ "must not be empty"
    refute Map.has_key?(empty_error, "id")

    conn = post_mcp(batch, nil, "2025-06-18")
    assert json_response(conn, 400)["error"]["message"] =~ "batches are not supported"
  end

  test "parse failures and malformed client responses have no response id" do
    parse_error = "{" |> raw_post_mcp(@protocol_version) |> json_response(400)
    assert parse_error["error"]["code"] == -32_700
    refute Map.has_key?(parse_error, "id")

    conn =
      post_mcp(
        %{"jsonrpc" => "2.0", "id" => 7, "result" => %{}, "error" => %{}},
        nil,
        @protocol_version
      )

    invalid = json_response(conn, 400)
    assert invalid["error"]["code"] == -32_600
    refute Map.has_key?(invalid, "id")
  end

  test "tools dispatch directly through the scheduler context", %{root: root} do
    relative_path = ".codex/workflows/http.exs"
    absolute_path = Path.join(root, relative_path)
    File.mkdir_p!(Path.dirname(absolute_path))

    File.write!(absolute_path, """
    workflow "mcp-http" do
      log "through scheduler"
      return :ok
    end
    """)

    canonical_path =
      absolute_path
      |> Path.dirname()
      |> File.cd!(fn -> Path.join(File.cwd!(), Path.basename(absolute_path)) end)

    validation =
      call_tool(10, "workflow_validate", %{
        "script_path" => relative_path,
        "workspace_root" => root
      })

    assert %{
             "result" => %{
               "isError" => false,
               "structuredContent" => %{
                 "api_version" => "scheduler.v1",
                 "data" => %{
                   "valid" => true,
                   "workflow_name" => "mcp-http",
                   "script" => %{"path" => ^canonical_path}
                 }
               }
             }
           } = validation

    missing_root = call_tool(11, "workflow_validate", %{"script_path" => relative_path})

    assert get_in(missing_root, ["result", "isError"]) == true

    assert get_in(missing_root, ["result", "structuredContent", "error", "code"]) ==
             "scheduler.run.invalid_workspace_root"

    run_id = "mcp_http_#{System.unique_integer([:positive])}"

    started =
      call_tool(12, "workflow_start", %{
        "script_path" => relative_path,
        "workspace_root" => root,
        "run_id" => run_id,
        "provider" => "mock"
      })

    assert get_in(started, ["result", "structuredContent", "data", "run_id"]) == run_id
    await_completed(run_id)

    status = call_tool(13, "workflow_status", %{"run_id" => run_id})
    status_data = get_in(status, ["result", "structuredContent", "data"])
    assert status_data["runId"] == run_id
    assert status_data["state"] == "completed"
    refute Map.has_key?(status_data, "uiUrl")

    inspected = call_tool(14, "workflow_inspect", %{"run_id" => run_id})
    inspect_data = get_in(inspected, ["result", "structuredContent", "data"])
    assert is_list(inspect_data["journalEvents"])
    assert is_map(inspect_data["rawRefs"])

    opened = call_tool(15, "workflow_open_ui", %{"run_id" => run_id})
    open_data = get_in(opened, ["result", "structuredContent", "data"])
    assert open_data["open_url"] == Endpoint.url() <> "/runs/#{run_id}"

    alias_resume =
      call_tool(16, "workflow_resume", %{
        "run_id" => "missing-run",
        "script" => relative_path,
        "workspace_root" => root,
        "provider" => "mock"
      })

    assert get_in(alias_resume, ["result", "structuredContent", "error", "code"]) ==
             "scheduler.run.not_found"
  end

  defp initialize_request(id) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => @protocol_version,
        "capabilities" => %{},
        "clientInfo" => %{"name" => "test", "version" => "1"}
      }
    }
  end

  defp call_tool(id, name, arguments) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "tools/call",
      "params" => %{"name" => name, "arguments" => arguments}
    }
    |> post_mcp(nil, @protocol_version)
    |> json_response(200)
  end

  defp post_mcp(message, origin \\ nil, protocol_version \\ nil) do
    message
    |> Jason.encode!()
    |> raw_post_mcp(protocol_version, origin)
  end

  defp raw_post_mcp(body, protocol_version, origin \\ nil) do
    conn =
      loopback_conn()
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "application/json, text/event-stream")
      |> maybe_put_header("mcp-protocol-version", protocol_version)
      |> maybe_put_header("origin", origin)

    post(conn, "/mcp", body)
  end

  defp maybe_put_header(conn, _name, nil), do: conn
  defp maybe_put_header(conn, name, value), do: put_req_header(conn, name, value)

  defp loopback_conn do
    %{build_conn() | host: "localhost", port: 47_125}
  end

  defp await_completed(run_id, attempts \\ 100)
  defp await_completed(run_id, 0), do: flunk("run #{run_id} did not complete")

  defp await_completed(run_id, attempts) do
    case Scheduler.get_run(run_id) do
      {:ok, %{state: :completed}} ->
        :ok

      _other ->
        Process.sleep(5)
        await_completed(run_id, attempts - 1)
    end
  end
end
