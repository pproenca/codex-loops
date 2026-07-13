defmodule ProofMCPValidate do
  @moduledoc false

  @protocol_version "2025-11-25"
  @http_timeout_ms 2_000
  @startup_timeout_ms 20_000
  @shutdown_timeout_ms 15_000
  @poll_attempts 200
  @poll_interval_ms 100
  @max_response_bytes 8 * 1_024 * 1_024
  @max_release_log_bytes 1 * 1_024 * 1_024
  @conformance_workflows [
    %{
      file: "conformance_core.exs",
      name: "conformance-core",
      result: :ok,
      events:
        ~w(parallel_started pipeline_started verify_started judge_started loop_decision accumulate fanout_started run_completed)
    },
    %{
      file: "conformance_dataflow.exs",
      name: "conformance-dataflow",
      result: :dataflow,
      events: ~w(agent_activity fanout_started fanout_completed run_completed)
    },
    %{
      file: "conformance_refine.exs",
      name: "conformance-refine",
      result: :refine,
      events:
        ~w(refine_started refine_round_started refine_round_decision refine_gate_evaluated refine_completed run_completed)
    }
  ]

  def run do
    {:ok, _apps} = Application.ensure_all_started(:inets)
    previous_trap_exit = Process.flag(:trap_exit, true)
    repo_root = Path.expand("..", __DIR__)
    temp_root = make_temp_root("codex-loops-mcp-proof")
    port = proof_port!()
    scheduler_url = "http://127.0.0.1:#{port}"

    packaged_release =
      Path.join(repo_root, "_build/dev-bundle/libexec/scheduler/bin/codex-loops-server")

    package_version = package_version(repo_root)

    assert!(
      executable_file?(packaged_release),
      "development bundle should include the packaged OTP scheduler release"
    )

    workflow_path = Path.join(temp_root, "workflow.exs")
    invalid_workflow_path = Path.join(temp_root, "invalid-workflow.exs")
    missing_path = Path.join(temp_root, "missing-workflow.exs")
    journal_path = Path.join(temp_root, "runs.sqlite")
    run_id = "mcp:proof_#{System.unique_integer([:positive])}"
    unknown_run_id = "mcp:missing_#{System.unique_integer([:positive])}"

    File.write!(workflow_path, workflow_source())
    File.write!(invalid_workflow_path, invalid_workflow_source())
    binding = prepare_stub_binding!(temp_root, repo_root)

    try do
      release =
        start_release!(
          packaged_release,
          temp_root,
          release_env(temp_root, journal_path, port, binding)
        )

      try do
        release = wait_for_healthy!(release, scheduler_url, package_version)
        initialize!(scheduler_url, package_version, port)
        assert_tools_list!(rpc!(scheduler_url, "tools/list", %{}))
        prove_transport_edges!(scheduler_url)
        prove_disconnect_survival!(release, scheduler_url, port)

        prove_scheduler_tools!(
          scheduler_url,
          temp_root,
          workflow_path,
          invalid_workflow_path,
          missing_path,
          run_id,
          unknown_run_id
        )

        prove_conformance_workflows!(scheduler_url, repo_root)

        assert!(File.regular?(journal_path), "scheduler should persist the isolated SQLite journal")
        assert!(File.regular?(binding.path), "scheduler should use the isolated Codex binding")
        assert_release_alive!(release, "scheduler should remain alive until explicitly stopped")

        stop_release!(release)
        assert_scheduler_stopped!(scheduler_url)

        IO.puts("Streamable HTTP MCP validate/start/status/inspect/resume/open-ui proof passed on #{scheduler_url}")
      after
        stop_release(release)
      end
    after
      Process.flag(:trap_exit, previous_trap_exit)
      File.rm_rf(temp_root)
    end
  end

  defp initialize!(scheduler_url, package_version, port) do
    message = %{
      "jsonrpc" => "2.0",
      "id" => request_id(),
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => "2099-01-01",
        "capabilities" => %{},
        "clientInfo" => %{"name" => "proof-mcp-validate", "version" => package_version}
      }
    }

    response =
      post_mcp!(scheduler_url, Jason.encode!(message),
        protocol_version: nil,
        origin: "http://localhost:#{port}"
      )

    assert!(response.status == 200, "initialize should return HTTP 200: #{inspect(response)}")
    body = json_body!(response)

    assert!(
      get_in(body, ["result", "protocolVersion"]) == @protocol_version,
      "initialize should negotiate the newest supported protocol version"
    )

    assert!(
      get_in(body, ["result", "serverInfo", "name"]) == "codex-loops" and
        get_in(body, ["result", "serverInfo", "version"]) == package_version,
      "initialize should identify the packaged scheduler version"
    )

    assert!(
      get_in(body, ["result", "capabilities", "tools", "listChanged"]) == false,
      "initialize should advertise the stable tools capability"
    )
  end

  defp prove_transport_edges!(scheduler_url) do
    notification = %{
      "jsonrpc" => "2.0",
      "method" => "notifications/initialized",
      "params" => %{}
    }

    response = post_mcp!(scheduler_url, Jason.encode!(notification))
    assert!(response.status == 202, "notifications should return HTTP 202")
    assert!(response.body == "", "notification responses should have no body")

    for method <- [:get, :delete] do
      response =
        http_request!(method, scheduler_url <> "/mcp", [
          {"accept", "application/json, text/event-stream"}
        ])

      assert!(response.status == 405, "#{method} /mcp should return HTTP 405")
      assert!(response.headers["allow"] == "POST", "405 responses should advertise POST")
    end

    ping = Jason.encode!(json_rpc("ping", %{}))

    hostile = post_mcp!(scheduler_url, ping, origin: "https://attacker.example")
    assert_json_rpc_error!(hostile, 403, -32_600, "hostile Origin should be forbidden")

    stale_version = post_mcp!(scheduler_url, ping, protocol_version: "2024-11-05")
    assert_json_rpc_error!(stale_version, 400, -32_600, "unsupported protocol headers should fail")

    malformed = post_mcp!(scheduler_url, "{")
    assert_json_rpc_error!(malformed, 400, -32_700, "malformed JSON should return parse error")

    wrong_type = post_mcp!(scheduler_url, ping, content_type: "text/plain")
    assert_json_rpc_error!(wrong_type, 415, -32_600, "non-JSON content should be rejected")

    wrong_accept = post_mcp!(scheduler_url, ping, accept: "application/json")
    assert_json_rpc_error!(wrong_accept, 406, -32_600, "Streamable HTTP Accept should be enforced")

    oversized =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => request_id(),
        "method" => "tools/call",
        "params" => %{
          "name" => "workflow_validate",
          "arguments" => %{"padding" => String.duplicate("x", 1_048_576)}
        }
      })

    too_large = post_mcp!(scheduler_url, oversized)
    assert_json_rpc_error!(too_large, 413, -32_600, "oversized request bodies should be rejected")

    invalid_call = rpc!(scheduler_url, "tools/call", %{"name" => "workflow_start", "arguments" => %{}})

    assert!(
      get_in(invalid_call, ["error", "code"]) == -32_602,
      "invalid tool arguments should return JSON-RPC invalid params"
    )

    assert!(get_in(rpc!(scheduler_url, "ping", %{}), ["result"]) == %{}, "ping should succeed")
  end

  defp prove_disconnect_survival!(release, scheduler_url, port) do
    before_pid = release.os_pid

    {:ok, socket} =
      :gen_tcp.connect(
        {127, 0, 0, 1},
        port,
        [:binary, {:active, false}, {:packet, :raw}],
        @http_timeout_ms
      )

    partial_request = [
      "POST /mcp HTTP/1.1\r\n",
      "Host: 127.0.0.1:#{port}\r\n",
      "Content-Type: application/json\r\n",
      "Accept: application/json, text/event-stream\r\n",
      "MCP-Protocol-Version: #{@protocol_version}\r\n",
      "Content-Length: 512\r\n",
      "Connection: close\r\n\r\n",
      ~s({"jsonrpc":"2.0","id":1)
    ]

    :ok = :gen_tcp.send(socket, partial_request)
    Process.sleep(50)
    :ok = :gen_tcp.close(socket)
    Process.sleep(50)

    assert_release_alive!(release, "a disconnected HTTP client must not stop the scheduler")
    assert!(release.os_pid == before_pid, "client disconnect should not replace the scheduler process")
    assert_healthy!(scheduler_url)
    assert!(get_in(rpc!(scheduler_url, "ping", %{}), ["result"]) == %{}, "MCP should survive disconnect")
  end

  defp prove_scheduler_tools!(
         scheduler_url,
         workspace_root,
         workflow_path,
         invalid_workflow_path,
         missing_path,
         run_id,
         unknown_run_id
       ) do
    relative_path = Path.relative_to(workflow_path, workspace_root)

    missing_root = call_tool!(scheduler_url, "workflow_validate", %{"script_path" => relative_path})
    missing_root_payload = error_tool_payload!(missing_root, "workflow_validate")

    assert!(
      missing_root_payload["error"]["code"] == "scheduler.run.invalid_workspace_root",
      "relative workflow paths should require an explicit absolute workspace_root"
    )

    relative_validation =
      call_tool!(scheduler_url, "workflow_validate", %{
        "script_path" => relative_path,
        "workspace_root" => workspace_root
      })

    assert_successful_validation!(relative_validation, workflow_path, "mcp-transport-proof")

    missing_validation =
      call_tool!(scheduler_url, "workflow_validate", %{"script_path" => missing_path})

    assert_scheduler_error!(
      missing_validation,
      "workflow_validate",
      "scheduler.validation.script_not_found"
    )

    invalid_validation =
      call_tool!(scheduler_url, "workflow_validate", %{"script_path" => invalid_workflow_path})

    assert_scheduler_error!(
      invalid_validation,
      "workflow_validate",
      "scheduler.validation.workflow_dsl"
    )

    start =
      call_tool!(scheduler_url, "workflow_start", %{
        "script_path" => relative_path,
        "workspace_root" => workspace_root,
        "run_id" => run_id,
        "provider" => "mock",
        "budget" => 0
      })

    assert_started_run!(start, run_id, "workflow_start")
    status = poll_completed_status!(scheduler_url, run_id)
    assert_completed_status!(status, run_id, "mcp-transport-proof")

    inspection = call_tool!(scheduler_url, "workflow_inspect", %{"run_id" => run_id})
    assert_inspected_events!(inspection, run_id)

    resume =
      call_tool!(scheduler_url, "workflow_resume", %{
        "run_id" => run_id,
        "script" => relative_path,
        "workspace_root" => workspace_root,
        "provider" => "mock"
      })

    assert_started_run!(resume, run_id, "workflow_resume")
    resumed_status = poll_completed_status!(scheduler_url, run_id)
    assert_completed_status!(resumed_status, run_id, "mcp-transport-proof")

    open_ui = call_tool!(scheduler_url, "workflow_open_ui", %{"run_id" => run_id})
    assert_open_ui!(open_ui, run_id, scheduler_url)

    unknown = call_tool!(scheduler_url, "workflow_status", %{"run_id" => unknown_run_id})
    assert_scheduler_error!(unknown, "workflow_status", "scheduler.run.not_found")
  end

  defp prove_conformance_workflows!(scheduler_url, repo_root) do
    Enum.each(@conformance_workflows, fn workflow ->
      path = Path.join([repo_root, ".codex", "workflows", workflow.file])
      run_id = "mcp:#{workflow.name}_#{System.unique_integer([:positive])}"

      validation =
        call_tool!(scheduler_url, "workflow_validate", %{
          "script_path" => path,
          "workspace_root" => repo_root
        })

      assert_successful_validation!(validation, path, workflow.name)

      start =
        call_tool!(scheduler_url, "workflow_start", %{
          "script_path" => path,
          "workspace_root" => repo_root,
          "run_id" => run_id,
          "provider" => "codex",
          "budget" => 10_000
        })

      assert_started_run!(start, run_id, "workflow_start")
      status = poll_completed_status!(scheduler_url, run_id)
      assert_conformance_status!(status, run_id, workflow.name, workflow.result)

      inspection = call_tool!(scheduler_url, "workflow_inspect", %{"run_id" => run_id})
      assert_conformance_events!(inspection, run_id, workflow.events)
    end)
  end

  defp poll_completed_status!(scheduler_url, run_id) do
    do_poll_completed_status!(scheduler_url, run_id, @poll_attempts, nil)
  end

  defp do_poll_completed_status!(_scheduler_url, run_id, 0, last_payload) do
    raise("run #{run_id} did not complete; last status: #{inspect(last_payload, limit: :infinity)}")
  end

  defp do_poll_completed_status!(scheduler_url, run_id, attempts_left, _last_payload) do
    response = call_tool!(scheduler_url, "workflow_status", %{"run_id" => run_id})
    payload = successful_tool_payload!(response, "workflow_status")
    state = get_in(payload, ["data", "state"])

    case state do
      "completed" ->
        payload

      terminal when terminal in ["failed", "killed"] ->
        raise(
          "run #{run_id} reached terminal state #{terminal}: " <>
            inspect(get_in(payload, ["data", "failure"]), limit: :infinity)
        )

      _nonterminal ->
        Process.sleep(@poll_interval_ms)
        do_poll_completed_status!(scheduler_url, run_id, attempts_left - 1, payload)
    end
  end

  defp assert_tools_list!(%{"result" => %{"tools" => tools}}) when is_list(tools) do
    expected = [
      "workflow_validate",
      "workflow_start",
      "workflow_status",
      "workflow_inspect",
      "workflow_resume",
      "workflow_open_ui"
    ]

    assert!(Enum.map(tools, & &1["name"]) == expected, "tools/list should expose exactly six tools")

    assert!(
      Enum.all?(tools, &(&1["inputSchema"]["additionalProperties"] == false)),
      "every MCP tool schema should reject unknown arguments"
    )

    resume = Enum.find(tools, &(&1["name"] == "workflow_resume"))

    assert!(
      resume["inputSchema"]["properties"]["script"] ==
        resume["inputSchema"]["properties"]["script_path"],
      "workflow_resume should preserve the legacy script alias"
    )

    assert!(
      Enum.all?(tools, &(not String.contains?(&1["description"], "/api/"))),
      "scheduler-owned MCP metadata should not claim an internal HTTP hop"
    )
  end

  defp assert_tools_list!(message), do: raise("tools/list response was not valid: #{inspect(message)}")

  defp assert_successful_validation!(response, workflow_path, workflow_name) do
    payload = successful_tool_payload!(response, "workflow_validate")
    data = payload["data"]

    assert!(payload["api_version"] == "scheduler.v1", "validation should use scheduler.v1")
    assert!(data["valid"] == true, "workflow should validate")
    assert!(data["workflow_name"] == workflow_name, "workflow name should be preserved")
    assert!(data["script"]["path"] == workflow_path, "canonical script path should be preserved")
  end

  defp assert_started_run!(response, run_id, tool_name) do
    payload = successful_tool_payload!(response, tool_name)
    data = payload["data"]

    assert!(payload["api_version"] == "scheduler.v1", "#{tool_name} should use scheduler.v1")
    assert!(data["run_id"] == run_id, "#{tool_name} should preserve run id")
    assert!(data["state"] == "accepted", "#{tool_name} should accept the run")
    assert!(data["ui_path"] == "/runs/#{run_id}", "#{tool_name} should return the UI path")
  end

  defp assert_completed_status!(payload, run_id, workflow_name) do
    data = payload["data"]

    assert!(payload["api_version"] == "scheduler.v1", "workflow_status should use scheduler.v1")
    assert!(data["runId"] == run_id, "workflow_status should preserve run id")
    assert!(data["state"] == "completed", "workflow_status should report completion")
    assert!(data["treeName"] == workflow_name, "workflow_status should project workflow name")
    assert!(data["result"] == "ok", "workflow_status should project the result")
    assert!(data["failure"] == nil, "successful status should not contain a failure")
    refute_key!(data, "uiPath", "workflow_status should expose only the public MCP projection")
    refute_key!(data, "lifecycleAction", "workflow_status should hide scheduler-only lifecycle data")
  end

  defp assert_inspected_events!(response, run_id) do
    payload = successful_tool_payload!(response, "workflow_inspect")
    data = payload["data"]
    events = data["journalEvents"]

    assert!(data["runId"] == run_id, "workflow_inspect should preserve run id")
    assert!(is_list(events) and events != [], "workflow_inspect should expose ordered journal events")
    assert!(Enum.map(events, & &1["seq"]) == Enum.to_list(0..(length(events) - 1)), "events should be ordered")
    assert!(List.last(events)["type"] == "run_completed", "inspection should include terminal event")
    refute_key!(data, "events", "workflow_inspect should hide its deprecated duplicate event field")
  end

  defp assert_open_ui!(response, run_id, scheduler_url) do
    payload = successful_tool_payload!(response, "workflow_open_ui")
    data = payload["data"]

    assert!(payload["api_version"] == "codex-loops.mcp.v1", "open UI should use the MCP envelope")
    assert!(data["runId"] == run_id, "open UI should preserve run id")
    assert!(data["open_url"] == "#{scheduler_url}/runs/#{run_id}", "open UI should return an absolute URL")
  end

  defp assert_conformance_status!(payload, run_id, workflow_name, result_shape) do
    data = payload["data"]

    assert!(data["runId"] == run_id, "conformance status should preserve run id")
    assert!(data["treeName"] == workflow_name, "conformance workflow name should be projected")
    assert!(data["state"] == "completed", "conformance workflow should complete")
    assert!(data["failure"] == nil, "conformance workflow should not fail")
    assert!(data["usage"]["totalTokens"] > 0, "conformance should traverse the shared Codex app-server")
    assert_conformance_result!(data["result"], result_shape)
  end

  defp assert_conformance_result!("ok", :ok), do: :ok

  defp assert_conformance_result!(result, :dataflow) do
    assert!(
      result == "Rows=2 Work=2 First=conformance-ok Summary=CONFORMANCE-OK",
      "dataflow conformance should preserve bindings and terminal rendering"
    )
  end

  defp assert_conformance_result!(%{"artifact" => "CONFORMANCE-OK", "converged" => true}, :refine), do: :ok

  defp assert_conformance_result!(result, shape) do
    raise("unexpected #{shape} conformance result: #{inspect(result)}")
  end

  defp assert_conformance_events!(response, run_id, expected_types) do
    payload = successful_tool_payload!(response, "workflow_inspect")
    data = payload["data"]
    event_types = Enum.map(get_in(data, ["rawRefs", "journal"]), & &1["type"])

    assert!(data["runId"] == run_id, "conformance inspect should preserve run id")

    for type <- expected_types do
      assert!(type in event_types, "conformance journal should include #{type}")
    end
  end

  defp assert_scheduler_error!(response, tool_name, expected_code) do
    payload = error_tool_payload!(response, tool_name)

    assert!(payload["api_version"] == "scheduler.v1", "#{tool_name} error should use scheduler.v1")

    assert!(
      payload["error"]["code"] == expected_code,
      "#{tool_name} should return #{expected_code}: #{inspect(payload)}"
    )

    payload
  end

  defp successful_tool_payload!(%{"result" => result}, tool_name) do
    assert!(result["isError"] == false, "#{tool_name} should not be an MCP error: #{inspect(result)}")
    assert_content_matches!(result, tool_name)
  end

  defp successful_tool_payload!(message, tool_name),
    do: raise("#{tool_name} success response was not valid: #{inspect(message)}")

  defp error_tool_payload!(%{"result" => result}, tool_name) do
    assert!(result["isError"] == true, "#{tool_name} should be an MCP tool error")
    assert_content_matches!(result, tool_name)
  end

  defp error_tool_payload!(message, tool_name),
    do: raise("#{tool_name} error response was not valid: #{inspect(message)}")

  defp assert_content_matches!(result, tool_name) do
    assert!(
      match?([%{"type" => "text", "text" => text}] when is_binary(text), result["content"]),
      "#{tool_name} should return exactly one JSON text content item"
    )

    [%{"text" => text}] = result["content"]

    assert!(
      Jason.decode!(text) == result["structuredContent"],
      "#{tool_name} text and structuredContent should encode the same payload"
    )

    result["structuredContent"]
  end

  defp refute_key!(map, key, message), do: assert!(not Map.has_key?(map, key), message)

  defp call_tool!(scheduler_url, name, arguments) do
    rpc!(scheduler_url, "tools/call", %{"name" => name, "arguments" => arguments})
  end

  defp rpc!(scheduler_url, method, params) do
    message = json_rpc(method, params)
    response = post_mcp!(scheduler_url, Jason.encode!(message))
    assert!(response.status == 200, "#{method} should return HTTP 200: #{inspect(response)}")
    json_body!(response)
  end

  defp json_rpc(method, params) do
    %{"jsonrpc" => "2.0", "id" => request_id(), "method" => method, "params" => params}
  end

  defp request_id, do: System.unique_integer([:positive, :monotonic])

  defp post_mcp!(scheduler_url, body, opts \\ []) do
    accept = Keyword.get(opts, :accept, "application/json, text/event-stream")
    protocol_version = Keyword.get(opts, :protocol_version, @protocol_version)
    origin = Keyword.get(opts, :origin)
    content_type = Keyword.get(opts, :content_type, "application/json")

    headers =
      []
      |> maybe_header("accept", accept)
      |> maybe_header("mcp-protocol-version", protocol_version)
      |> maybe_header("origin", origin)

    http_request!(:post, scheduler_url <> "/mcp", headers, {content_type, body})
  end

  defp maybe_header(headers, _name, nil), do: headers
  defp maybe_header(headers, name, value), do: [{name, value} | headers]

  defp assert_json_rpc_error!(response, status, code, message) do
    assert!(response.status == status, "#{message}: expected HTTP #{status}, got #{response.status}")
    assert!(get_in(json_body!(response), ["error", "code"]) == code, message)
  end

  defp json_body!(%{body: body}) when byte_size(body) > 0 do
    case Jason.decode(body) do
      {:ok, value} -> value
      {:error, reason} -> raise("HTTP response was not JSON: #{inspect(reason)} body=#{inspect(body)}")
    end
  end

  defp json_body!(response), do: raise("HTTP response had no JSON body: #{inspect(response)}")

  defp http_request!(method, url, headers, body \\ nil) do
    case http_request(method, url, headers, body) do
      {:ok, response} -> response
      {:error, reason} -> raise("HTTP #{method} #{url} failed: #{inspect(reason)}")
    end
  end

  defp http_request(method, url, headers, body) do
    request = http_request_tuple(method, url, headers, body)

    case :httpc.request(
           method,
           request,
           [timeout: @http_timeout_ms, connect_timeout: @http_timeout_ms],
           body_format: :binary
         ) do
      {:ok, {{_version, status, _reason}, response_headers, response_body}} ->
        body = IO.iodata_to_binary(response_body)

        if byte_size(body) <= @max_response_bytes do
          {:ok,
           %{
             status: status,
             headers: normalize_headers(response_headers),
             body: body
           }}
        else
          {:error, {:response_too_large, byte_size(body)}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp http_request_tuple(:post, url, headers, {content_type, body}) do
    {
      String.to_charlist(url),
      encode_headers(headers),
      String.to_charlist(content_type),
      body
    }
  end

  defp http_request_tuple(_method, url, headers, nil) do
    {String.to_charlist(url), encode_headers(headers)}
  end

  defp encode_headers(headers) do
    Enum.map(headers, fn {name, value} ->
      {String.to_charlist(name), String.to_charlist(value)}
    end)
  end

  defp normalize_headers(headers) do
    Map.new(headers, fn {name, value} ->
      {name |> to_string() |> String.downcase(), to_string(value)}
    end)
  end

  defp start_release!(release_path, working_directory, env) do
    release_tmp = Path.join(working_directory, "release-tmp")
    File.mkdir_p!(release_tmp)

    port =
      Port.open({:spawn_executable, String.to_charlist(release_path)}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        {:args, [~c"foreground"]},
        {:cd, String.to_charlist(working_directory)},
        {:env, encode_env([{"RELEASE_TMP", release_tmp} | env])}
      ])

    {:os_pid, os_pid} = Port.info(port, :os_pid)
    %{port: port, os_pid: os_pid, output: ""}
  end

  defp release_env(temp_root, journal_path, port, binding) do
    home = Path.join(temp_root, "home")

    [
      {"CODEX_LOOPS_SERVER", "1"},
      {"CODEX_LOOPS_HOST", "127.0.0.1"},
      {"CODEX_LOOPS_PORT", Integer.to_string(port)},
      {"PORT", Integer.to_string(port)},
      {"CODEX_LOOPS_JOURNAL_PATH", journal_path},
      {"CODEX_LOOPS_CODEX_BIN", binding.codex_path},
      {"CODEX_LOOPS_BINDING_PATH", binding.path},
      {"CODEX_LOOPS_CODEX_MODEL", false},
      {"CODEX_LOOPS_CODEX_SANDBOX", false},
      {"CODEX_LOOPS_CODEX_WORKDIR", false},
      {"CODEX_ACCESS_TOKEN", false},
      {"CODEX_HOME", Path.join(home, ".codex")},
      {"HOME", home},
      {"RELEASE_DISTRIBUTION", "none"},
      {"RELEASE_NODE", "codex_loops_mcp_proof_#{System.unique_integer([:positive])}"}
    ]
  end

  defp encode_env(env) do
    Enum.map(env, fn
      {name, false} -> {String.to_charlist(name), false}
      {name, value} -> {String.to_charlist(name), String.to_charlist(value)}
    end)
  end

  defp wait_for_healthy!(release, scheduler_url, package_version) do
    deadline = System.monotonic_time(:millisecond) + @startup_timeout_ms
    do_wait_for_healthy!(release, scheduler_url, package_version, deadline, nil)
  end

  defp do_wait_for_healthy!(release, scheduler_url, package_version, deadline, last_error) do
    release = drain_release!(release)

    case health(scheduler_url) do
      {:ok, %{"api_version" => "scheduler.v1", "data" => %{"status" => "ok", "version" => ^package_version}}} ->
        release

      result ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(@poll_interval_ms)
          do_wait_for_healthy!(release, scheduler_url, package_version, deadline, result)
        else
          raise(
            "packaged scheduler did not become healthy: #{inspect(last_error || result)}\n" <>
              release_log(release)
          )
        end
    end
  end

  defp assert_healthy!(scheduler_url) do
    case health(scheduler_url) do
      {:ok, %{"data" => %{"status" => "ok"}}} -> :ok
      other -> raise("scheduler was not healthy after client disconnect: #{inspect(other)}")
    end
  end

  defp health(scheduler_url) do
    with {:ok, %{status: 200} = response} <-
           http_request(:get, scheduler_url <> "/api/health", [{"accept", "application/json"}], nil) do
      Jason.decode(response.body)
    end
  end

  defp assert_scheduler_stopped!(scheduler_url) do
    deadline = System.monotonic_time(:millisecond) + @shutdown_timeout_ms
    do_assert_scheduler_stopped!(scheduler_url, deadline)
  end

  defp do_assert_scheduler_stopped!(scheduler_url, deadline) do
    case health(scheduler_url) do
      {:error, _reason} ->
        :ok

      _still_running ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(@poll_interval_ms)
          do_assert_scheduler_stopped!(scheduler_url, deadline)
        else
          raise("scheduler still responded at #{scheduler_url} after SIGTERM")
        end
    end
  end

  defp drain_release!(release) do
    receive do
      {port, {:data, data}} when port == release.port ->
        release |> append_release_output(data) |> drain_release!()

      {port, {:exit_status, status}} when port == release.port ->
        raise("packaged scheduler exited unexpectedly with status #{status}\n#{release_log(release)}")

      {:EXIT, port, :normal} when port == release.port ->
        drain_release!(release)

      {:EXIT, port, reason} when port == release.port ->
        raise("packaged scheduler port exited unexpectedly: #{inspect(reason)}\n#{release_log(release)}")
    after
      0 -> release
    end
  end

  defp assert_release_alive!(release, message) do
    assert!(release_alive?(release), message <> "\n" <> release_log(release))
  end

  defp release_alive?(%{port: port}), do: not is_nil(Port.info(port))

  defp stop_release!(release) do
    assert_release_alive!(release, "packaged scheduler exited before explicit shutdown")

    case stop_release_result(release) do
      {:ok, status, release} ->
        assert!(
          status == 0,
          "packaged scheduler did not stop cleanly (status #{status})\n#{release_log(release)}"
        )

      {:error, reason, release} ->
        close_release_port(release.port)
        raise(stop_release_error(reason, release))
    end
  end

  defp stop_release(release) do
    case stop_release_result(release) do
      {:ok, _status, _release} ->
        :ok

      {:error, _reason, release} ->
        close_release_port(release.port)
        :ok
    end
  end

  defp stop_release_result(release) do
    if release_alive?(release) do
      case signal_release(release.os_pid) do
        :ok -> await_release_exit(release)
        {:error, reason} -> {:error, reason, release}
      end
    else
      {:ok, :already_stopped, release}
    end
  end

  defp signal_release(os_pid) do
    case System.cmd("/bin/kill", ["-TERM", Integer.to_string(os_pid)], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> {:error, {:signal_failed, status, String.trim(output)}}
    end
  end

  defp await_release_exit(release) do
    deadline = System.monotonic_time(:millisecond) + @shutdown_timeout_ms
    do_await_release_exit(release, deadline)
  end

  defp do_await_release_exit(release, deadline) do
    timeout = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {port, {:data, data}} when port == release.port ->
        release |> append_release_output(data) |> do_await_release_exit(deadline)

      {port, {:exit_status, status}} when port == release.port ->
        {:ok, status, release}

      {:EXIT, port, _reason} when port == release.port ->
        do_await_release_exit(release, deadline)
    after
      timeout ->
        {:error, :shutdown_timeout, release}
    end
  end

  defp stop_release_error({:signal_failed, status, output}, release) do
    "could not SIGTERM packaged scheduler (#{status}): #{output}\n#{release_log(release)}"
  end

  defp stop_release_error(:shutdown_timeout, release) do
    "timed out waiting for packaged scheduler shutdown\n#{release_log(release)}"
  end

  defp close_release_port(port) do
    if Port.info(port), do: Port.close(port)
  rescue
    # The external OS port can exit between Port.info/1 and Port.close/1.
    ArgumentError -> :ok
  end

  defp append_release_output(release, data) do
    output = release.output <> data
    size = byte_size(output)

    output =
      if size > @max_release_log_bytes do
        binary_part(output, size - @max_release_log_bytes, @max_release_log_bytes)
      else
        output
      end

    %{release | output: output}
  end

  defp release_log(%{output: ""}), do: "(scheduler emitted no captured output)"
  defp release_log(%{output: output}), do: "scheduler output:\n#{output}"

  defp prepare_stub_binding!(temp_root, repo_root) do
    home = Path.join(temp_root, "home")
    codex_path = Path.join(temp_root, "codex-proof")
    binding_path = Path.join(home, ".codex/workflows/codex-binding.json")
    stub_path = Path.join(repo_root, "scripts/support/codex-conformance-stub.py")
    File.mkdir_p!(Path.dirname(binding_path))

    File.write!(
      codex_path,
      """
      #!/usr/bin/env python3
      import os
      import sys

      if sys.argv[1:] == ["--version"]:
          print("codex-cli proof")
      else:
          stub = #{Jason.encode!(stub_path)}
          os.execv(stub, [stub])
      """
    )

    File.chmod!(codex_path, 0o755)

    File.write!(
      binding_path,
      Jason.encode!(%{"path" => codex_path, "version" => "codex-cli proof"}, pretty: true)
    )

    %{path: binding_path, codex_path: codex_path}
  end

  defp workflow_source do
    """
    workflow "mcp-transport-proof" do
      phase "proof"
      log "mcp transport proof"
      agent "Reply with proof-ok"
      return :ok
    end
    """
  end

  defp invalid_workflow_source do
    """
    workflow "mcp-invalid-proof" do
      raise "nope"
    end
    """
  end

  defp proof_port! do
    case System.get_env("CODEX_LOOPS_MCP_PROOF_PORT") do
      nil -> reserve_port!()
      value -> parse_port!(value)
    end
  end

  defp parse_port!(value) do
    case Integer.parse(value) do
      {port, ""} when port in 1..65_535 -> port
      _ -> raise("CODEX_LOOPS_MCP_PROOF_PORT must be an integer from 1 to 65535")
    end
  end

  defp reserve_port! do
    {:ok, socket} =
      :gen_tcp.listen(0, [
        :binary,
        {:active, false},
        {:ip, {127, 0, 0, 1}},
        {:reuseaddr, true}
      ])

    {:ok, {{127, 0, 0, 1}, port}} = :inet.sockname(socket)
    :ok = :gen_tcp.close(socket)
    port
  end

  defp make_temp_root(prefix) do
    path =
      Path.join(
        System.tmp_dir!(),
        "#{prefix}-#{System.system_time(:nanosecond)}-#{System.unique_integer([:positive])}"
      )

    File.mkdir!(path)
    File.cd!(path, &File.cwd!/0)
  end

  defp package_version(repo_root) do
    repo_root
    |> Path.join("VERSION")
    |> File.read!()
    |> String.trim()
  end

  defp executable_file?(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, mode: mode}} -> Bitwise.band(mode, 0o111) != 0
      _other -> false
    end
  end

  defp assert!(true, _message), do: :ok
  defp assert!(false, message), do: raise(message)
end

ProofMCPValidate.run()
