defmodule Workflow.MCPAnubisValidateTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Workflow.MCP.AnubisStdio

  setup do
    previous_url = System.get_env("CODEX_LOOPS_SCHEDULER_URL")
    previous_timeout = System.get_env("CODEX_LOOPS_SCHEDULER_REQUEST_TIMEOUT_MS")

    System.put_env("CODEX_LOOPS_SCHEDULER_REQUEST_TIMEOUT_MS", "1000")

    on_exit(fn ->
      restore_env("CODEX_LOOPS_SCHEDULER_URL", previous_url)
      restore_env("CODEX_LOOPS_SCHEDULER_REQUEST_TIMEOUT_MS", previous_timeout)
    end)

    :ok
  end

  test "legacy hand-rolled stdio adapter is not compiled" do
    refute Code.ensure_loaded?(Workflow.MCP.Stdio)
  end

  test "Anubis stdio server initializes and lists the full workflow tool surface" do
    responses =
      [initialize(1), initialized(), tools_list(2)]
      |> run_stdio()
      |> responses_by_id()

    assert responses[1]["result"]["serverInfo"]["name"] == "codex-loops"
    assert responses[1]["result"]["capabilities"]["tools"] == %{}

    tools_by_name = Map.new(responses[2]["result"]["tools"], &{&1["name"], &1})

    assert Map.keys(tools_by_name) == [
             "workflow_inspect",
             "workflow_open_ui",
             "workflow_resume",
             "workflow_start",
             "workflow_status",
             "workflow_validate"
           ]

    assert tools_by_name["workflow_validate"]["description"] =~ "Validate"
    assert tools_by_name["workflow_start"]["description"] =~ "POST /api/runs"
    assert tools_by_name["workflow_status"]["description"] =~ "GET /api/runs/:id"
    assert tools_by_name["workflow_inspect"]["description"] =~ "/events"
    assert tools_by_name["workflow_resume"]["description"] =~ "/resume"
    assert tools_by_name["workflow_open_ui"]["description"] =~ "LiveView URL"
    assert tools_by_name["workflow_validate"]["inputSchema"]["required"] == ["script_path"]
  end

  test "Anubis stdio entrypoint handles help" do
    {:ok, io} = StringIO.open("")

    assert :ok = AnubisStdio.main(["--help"], output_device: io)

    {_input, output} = StringIO.contents(io)
    assert output =~ "Usage: codex-loops-mcp --stdio"
    assert output =~ "Runs the Codex Loops Anubis MCP server over stdio."
  end

  test "Anubis stdio entrypoint rejects invalid arguments without halting when requested" do
    {:ok, io} = StringIO.open("")

    assert {:error, 2} = AnubisStdio.main(["--wat"], error_device: io, halt?: false)

    {_input, output} = StringIO.contents(io)
    assert output =~ "Invalid arguments."
    assert output =~ "Usage: codex-loops-mcp --stdio"
  end

  test "workflow_validate calls the scheduler HTTP API and returns structured content" do
    envelope = %{
      "api_version" => "scheduler.v1",
      "data" => %{
        "status" => "valid",
        "script_path" => ".codex/workflows/demo.exs"
      }
    }

    url = serve_sequence([health_envelope(), envelope])
    System.put_env("CODEX_LOOPS_SCHEDULER_URL", url)

    responses =
      [initialize(1), initialized(), workflow_validate(2, ".codex/workflows/demo.exs")]
      |> run_stdio()
      |> responses_by_id()

    result = responses[2]["result"]
    assert result["isError"] == false
    assert result["structuredContent"] == envelope
    assert [%{"type" => "text", "text" => text}] = result["content"]
    assert Jason.decode!(text) == envelope

    [health_request, validate_request] = receive_requests(2)
    assert health_request =~ "GET /api/health "
    assert validate_request =~ "POST /api/workflows/validate "
    assert validate_request =~ ~s("script_path":".codex/workflows/demo.exs")
  end

  test "workflow_start calls POST /api/runs with allowed arguments only" do
    envelope = %{
      "api_version" => "scheduler.v1",
      "data" => %{"runId" => "run-1", "state" => "running", "uiUrl" => "/runs/run-1"}
    }

    url = serve_sequence([health_envelope(), envelope])
    System.put_env("CODEX_LOOPS_SCHEDULER_URL", url)

    responses =
      [
        initialize(1),
        initialized(),
        tool_call(2, "workflow_start", %{
          "script_path" => "demo.exs",
          "run_id" => "run-1",
          "provider" => "mock",
          "budget" => 10,
          "ignored" => true
        })
      ]
      |> run_stdio()
      |> responses_by_id()

    assert responses[2]["result"]["isError"] == false
    assert responses[2]["result"]["structuredContent"] == envelope

    [_health_request, start_request] = receive_requests(2)
    assert start_request =~ "POST /api/runs "

    body = request_body(start_request)

    assert Jason.decode!(body) == %{
             "script_path" => "demo.exs",
             "run_id" => "run-1",
             "provider" => "mock",
             "budget" => 10
           }
  end

  test "workflow_status calls GET /api/runs/:id and conforms projection envelopes" do
    envelope = %{
      "api_version" => "scheduler.v1",
      "data" => %{
        "runId" => "run 1",
        "state" => "done",
        "treeName" => "demo",
        "agentCount" => 0,
        "eventCount" => 1,
        "rawRefs" => %{"journal" => []},
        "uiPath" => "/runs/run%201",
        "uiUrl" => "/runs/run%201"
      }
    }

    url = serve_sequence([health_envelope(), envelope])
    System.put_env("CODEX_LOOPS_SCHEDULER_URL", url)

    responses =
      [initialize(1), initialized(), tool_call(2, "workflow_status", %{"run_id" => "run 1"})]
      |> run_stdio()
      |> responses_by_id()

    data = responses[2]["result"]["structuredContent"]["data"]
    assert data["runId"] == "run 1"
    refute Map.has_key?(data, "uiPath")
    refute Map.has_key?(data, "uiUrl")

    [_health_request, status_request] = receive_requests(2)
    assert status_request =~ "GET /api/runs/run%201 "
  end

  test "workflow_inspect calls GET /api/runs/:id/events" do
    envelope = %{
      "api_version" => "scheduler.v1",
      "data" => %{
        "runId" => "run-inspect",
        "state" => "running",
        "rawRefs" => %{"journal" => [%{"seq" => 0}]},
        "events" => [%{"seq" => 0, "type" => "run_started"}]
      }
    }

    url = serve_sequence([health_envelope(), envelope])
    System.put_env("CODEX_LOOPS_SCHEDULER_URL", url)

    responses =
      [
        initialize(1),
        initialized(),
        tool_call(2, "workflow_inspect", %{"run_id" => "run-inspect"})
      ]
      |> run_stdio()
      |> responses_by_id()

    data = responses[2]["result"]["structuredContent"]["data"]
    assert data["runId"] == "run-inspect"
    assert data["rawRefs"] == %{"journal" => [%{"seq" => 0}]}
    refute Map.has_key?(data, "events")

    [_health_request, inspect_request] = receive_requests(2)
    assert inspect_request =~ "GET /api/runs/run-inspect/events "
  end

  test "workflow_resume calls POST /api/runs/:id/resume with allowed arguments only" do
    envelope = %{
      "api_version" => "scheduler.v1",
      "data" => %{"runId" => "run-resume", "state" => "running"}
    }

    url = serve_sequence([health_envelope(), envelope])
    System.put_env("CODEX_LOOPS_SCHEDULER_URL", url)

    responses =
      [
        initialize(1),
        initialized(),
        tool_call(2, "workflow_resume", %{
          "run_id" => "run-resume",
          "script_path" => "resume.exs",
          "provider" => "mock",
          "ignored" => true
        })
      ]
      |> run_stdio()
      |> responses_by_id()

    assert responses[2]["result"]["structuredContent"] == envelope

    [_health_request, resume_request] = receive_requests(2)
    assert resume_request =~ "POST /api/runs/run-resume/resume "

    assert Jason.decode!(request_body(resume_request)) == %{
             "script_path" => "resume.exs",
             "provider" => "mock"
           }
  end

  test "workflow_open_ui calls GET /api/runs/:id and adds absolute open_url" do
    envelope = %{
      "api_version" => "scheduler.v1",
      "data" => %{
        "runId" => "run-open",
        "state" => "running",
        "uiPath" => "/runs/run-open"
      }
    }

    url = serve_sequence([health_envelope(), envelope])
    System.put_env("CODEX_LOOPS_SCHEDULER_URL", url)

    responses =
      [initialize(1), initialized(), tool_call(2, "workflow_open_ui", %{"run_id" => "run-open"})]
      |> run_stdio()
      |> responses_by_id()

    data = responses[2]["result"]["structuredContent"]["data"]
    assert data["open_url"] == url <> "/runs/run-open"

    [_health_request, open_request] = receive_requests(2)
    assert open_request =~ "GET /api/runs/run-open "
  end

  test "scheduler validation errors remain user-readable tool errors" do
    envelope = %{
      "api_version" => "scheduler.v1",
      "error" => %{
        "code" => "workflow_invalid",
        "message" => "Workflow script is invalid.",
        "details" => %{"line" => 3}
      }
    }

    url = serve_sequence([health_envelope(), {422, envelope}])
    System.put_env("CODEX_LOOPS_SCHEDULER_URL", url)

    responses =
      [initialize(1), initialized(), workflow_validate(2, "bad.exs")]
      |> run_stdio()
      |> responses_by_id()

    result = responses[2]["result"]
    assert result["isError"] == true
    assert result["structuredContent"] == envelope
    assert [%{"type" => "text", "text" => text}] = result["content"]
    assert text =~ "Workflow script is invalid."
  end

  test "bad run id scheduler errors remain user-readable tool errors" do
    envelope = %{
      "api_version" => "scheduler.v1",
      "error" => %{
        "code" => "run_not_found",
        "message" => "Run not found.",
        "details" => %{"run_id" => "missing"}
      }
    }

    url = serve_sequence([health_envelope(), {404, envelope}])
    System.put_env("CODEX_LOOPS_SCHEDULER_URL", url)

    responses =
      [initialize(1), initialized(), tool_call(2, "workflow_status", %{"run_id" => "missing"})]
      |> run_stdio()
      |> responses_by_id()

    result = responses[2]["result"]
    assert result["isError"] == true
    assert result["structuredContent"] == envelope
    assert get_in(result, ["structuredContent", "error", "code"]) == "run_not_found"
  end

  test "unexpected scheduler HTTP responses become tool errors" do
    payload = %{"ok" => true}

    url = serve_sequence([health_envelope(), payload])
    System.put_env("CODEX_LOOPS_SCHEDULER_URL", url)

    responses =
      [
        initialize(1),
        initialized(),
        tool_call(2, "workflow_start", %{"script_path" => "demo.exs"})
      ]
      |> run_stdio()
      |> responses_by_id()

    result = responses[2]["result"]
    assert result["isError"] == true

    assert get_in(result, ["structuredContent", "error", "code"]) ==
             "scheduler_unexpected_response"

    assert get_in(result, ["structuredContent", "error", "details", "payload"]) == payload
  end

  test "missing scheduler readiness becomes a tool error" do
    previous_url = System.get_env("CODEX_LOOPS_SCHEDULER_URL")
    previous_timeout = System.get_env("CODEX_LOOPS_SCHEDULER_REQUEST_TIMEOUT_MS")

    System.put_env("CODEX_LOOPS_SCHEDULER_URL", "http://192.0.2.1:9")
    System.put_env("CODEX_LOOPS_SCHEDULER_REQUEST_TIMEOUT_MS", "50")

    responses =
      [
        initialize(1),
        initialized(),
        tool_call(2, "workflow_validate", %{"script_path" => "demo.exs"})
      ]
      |> run_stdio()
      |> responses_by_id()

    result = responses[2]["result"]
    assert result["isError"] == true
    assert get_in(result, ["structuredContent", "error", "code"]) == "scheduler_unavailable"

    restore_env("CODEX_LOOPS_SCHEDULER_URL", previous_url)
    restore_env("CODEX_LOOPS_SCHEDULER_REQUEST_TIMEOUT_MS", previous_timeout)
  end

  test "tool input validation returns readable invalid params errors" do
    parent = self()

    capture_log(fn ->
      responses =
        [initialize(1), initialized(), workflow_validate(2, 123)]
        |> run_stdio()
        |> responses_by_id()

      send(parent, {:responses, responses})
    end)

    assert_received {:responses, responses}

    assert responses[2]["error"]["code"] == -32_602
    assert responses[2]["error"]["message"] == "Invalid params"
    assert responses[2]["error"]["data"]["message"] =~ "script_path"
  end

  test "empty run_id returns readable invalid params errors" do
    parent = self()

    capture_log(fn ->
      responses =
        [initialize(1), initialized(), tool_call(2, "workflow_status", %{"run_id" => ""})]
        |> run_stdio()
        |> responses_by_id()

      send(parent, {:responses, responses})
    end)

    assert_received {:responses, responses}

    assert responses[2]["error"]["code"] == -32_602
    assert responses[2]["error"]["message"] == "Invalid params"
    assert responses[2]["error"]["data"]["message"] =~ "run_id"
  end

  defp run_stdio(messages) do
    input = Enum.map_join(messages, "", &(Jason.encode!(&1) <> "\n"))
    {:ok, io} = StringIO.open(input)
    assert :ok = AnubisStdio.main(["--stdio"], io_device: io)

    {_input, output} = StringIO.contents(io)

    output
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
  end

  defp responses_by_id(responses) do
    Map.new(responses, fn %{"id" => id} = response -> {id, response} end)
  end

  defp initialize(id) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => "2024-11-05",
        "capabilities" => %{},
        "clientInfo" => %{"name" => "codex-loops-test", "version" => "0.0.0"}
      }
    }
  end

  defp initialized do
    %{"jsonrpc" => "2.0", "method" => "notifications/initialized", "params" => %{}}
  end

  defp tools_list(id) do
    %{"jsonrpc" => "2.0", "id" => id, "method" => "tools/list", "params" => %{}}
  end

  defp workflow_validate(id, script_path) do
    tool_call(id, "workflow_validate", %{"script_path" => script_path})
  end

  defp tool_call(id, name, arguments) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "tools/call",
      "params" => %{
        "name" => name,
        "arguments" => arguments
      }
    }
  end

  defp serve_sequence(responses) do
    parent = self()

    {:ok, listen_socket} =
      :gen_tcp.listen(0, [
        :binary,
        packet: :raw,
        active: false,
        reuseaddr: true,
        ip: {127, 0, 0, 1}
      ])

    {:ok, port} = :inet.port(listen_socket)

    spawn_link(fn ->
      Enum.each(responses, fn response ->
        {status, envelope} = normalize_response(response)
        body = Jason.encode!(envelope)

        {:ok, socket} = :gen_tcp.accept(listen_socket, 1000)
        {:ok, request} = :gen_tcp.recv(socket, 0, 1000)
        send(parent, {:http_request, request})

        response = [
          "HTTP/1.1 ",
          Integer.to_string(status),
          " OK\r\n",
          "content-type: application/json\r\n",
          "content-length: ",
          Integer.to_string(byte_size(body)),
          "\r\nconnection: close\r\n\r\n",
          body
        ]

        :ok = :gen_tcp.send(socket, response)
        :gen_tcp.close(socket)
      end)

      :gen_tcp.close(listen_socket)
    end)

    "http://127.0.0.1:#{port}"
  end

  defp normalize_response({status, envelope}), do: {status, envelope}
  defp normalize_response(envelope), do: {200, envelope}

  defp health_envelope do
    %{
      "api_version" => "scheduler.v1",
      "data" => %{"status" => "ok"}
    }
  end

  defp receive_requests(count) do
    Enum.map(1..count, fn _index ->
      receive do
        {:http_request, request} -> request
      after
        1000 -> flunk("timed out waiting for scheduler request")
      end
    end)
  end

  defp request_body(request) do
    request
    |> String.split("\r\n\r\n", parts: 2)
    |> List.last()
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
