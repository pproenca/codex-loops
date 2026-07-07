defmodule ProofMCPValidate do
  @moduledoc false

  @http_timeout_ms 500
  @poll_attempts 100
  @poll_interval_ms 100
  @rpc_timeout_ms 15_000

  def run do
    repo_root = Path.expand("..", __DIR__)
    port = System.get_env("CODEX_LOOPS_MCP_PROOF_PORT") || reserve_port()

    temp_root =
      Path.join(System.tmp_dir!(), "codex-loops-mcp-proof-#{System.unique_integer([:positive])}")

    File.mkdir_p!(temp_root)

    source_plugin_root = Path.join(repo_root, "plugins/codex-loops")
    installed_plugin_root = Path.join(temp_root, "installed-plugin/codex-loops")
    File.mkdir_p!(Path.dirname(installed_plugin_root))
    File.cp_r!(source_plugin_root, installed_plugin_root)

    entrypoint = Path.join(installed_plugin_root, "mcp/codex-loops-mcp")
    packaged_scheduler = Path.join(installed_plugin_root, "scheduler/bin/agent_loops")

    assert!(
      executable_file?(packaged_scheduler),
      "copied plugin package should include scheduler release"
    )

    workflow_path = Path.join(temp_root, "workflow.exs")
    running_workflow_path = Path.join(temp_root, "running-workflow.exs")
    invalid_workflow_path = Path.join(temp_root, "invalid-workflow.exs")
    missing_path = Path.join(temp_root, "missing-workflow.exs")
    journal_path = Path.join(temp_root, "runs.sqlite")
    run_id = "mcp:proof_#{System.unique_integer([:positive])}"
    running_run_id = "mcp:proof_running_#{System.unique_integer([:positive])}"
    unknown_run_id = "mcp:proof_missing_#{System.unique_integer([:positive])}"
    scheduler_url = "http://127.0.0.1:#{port}"

    try do
      File.write!(workflow_path, workflow_source())
      File.write!(running_workflow_path, running_workflow_source())
      File.write!(invalid_workflow_path, invalid_workflow_source())

      with_mcp_client(entrypoint, repo_root, mcp_env(port, journal_path), fn client ->
        {initialize, client} =
          request!(client, 1, "initialize", %{
            "protocolVersion" => "2024-11-05",
            "capabilities" => %{},
            "clientInfo" => %{"name" => "proof-mcp-validate", "version" => "0.0.0"}
          })

        assert_initialize!(initialize)
        client = notify!(client, "notifications/initialized", %{})

        {tools, client} = request!(client, 2, "tools/list", %{})
        assert_tools_list!(tools)

        {validation, client} =
          call_tool!(client, 3, "workflow_validate", %{"script_path" => workflow_path})

        assert_successful_validation!(validation, workflow_path)

        {missing_validation, client} =
          call_tool!(client, 4, "workflow_validate", %{"script_path" => missing_path})

        assert_missing_script_validation!(missing_validation, missing_path)

        {running_start, client} =
          call_tool!(client, 5, "workflow_start", %{
            "script_path" => running_workflow_path,
            "run_id" => running_run_id,
            "provider" => "mock",
            "budget" => 0
          })

        assert_started_run!(running_start, running_run_id)

        {already_running, client} =
          call_tool!(client, 6, "workflow_resume", %{
            "run_id" => running_run_id,
            "provider" => "mock"
          })

        assert_already_running_resume!(already_running, running_run_id)
        {client, _running_status_payload} = poll_terminal_status!(client, running_run_id, 7)

        {start, client} =
          call_tool!(client, 150, "workflow_start", %{
            "script_path" => workflow_path,
            "run_id" => run_id,
            "provider" => "mock",
            "budget" => 0
          })

        assert_started_run!(start, run_id)

        {client, status_payload} = poll_completed_status!(client, run_id, 151)
        assert_completed_status!(status_payload, run_id)

        {inspect, client} = call_tool!(client, 250, "workflow_inspect", %{"run_id" => run_id})
        assert_inspected_events!(inspect, run_id)

        {resume, client} =
          call_tool!(client, 251, "workflow_resume", %{
            "run_id" => run_id,
            "provider" => "mock"
          })

        assert_resumed_run!(resume, run_id)

        {client, resumed_status_payload} = poll_completed_status!(client, run_id, 252)
        assert_completed_status!(resumed_status_payload, run_id)

        {inspect_after_resume, client} =
          call_tool!(client, 350, "workflow_inspect", %{"run_id" => run_id})

        assert_inspected_events!(inspect_after_resume, run_id)

        {unknown_inspect, client} =
          call_tool!(client, 351, "workflow_inspect", %{"run_id" => unknown_run_id})

        assert_unknown_run_error!(unknown_inspect, "workflow_inspect", unknown_run_id)

        {unknown_resume, client} =
          call_tool!(client, 352, "workflow_resume", %{
            "run_id" => unknown_run_id,
            "provider" => "mock"
          })

        assert_unknown_run_error!(unknown_resume, "workflow_resume", unknown_run_id)

        {missing_resume, client} =
          call_tool!(client, 353, "workflow_resume", %{
            "run_id" => run_id,
            "script_path" => missing_path,
            "provider" => "mock"
          })

        assert_missing_script_resume!(missing_resume, missing_path)

        {validation_resume, client} =
          call_tool!(client, 354, "workflow_resume", %{
            "run_id" => run_id,
            "script_path" => invalid_workflow_path,
            "provider" => "mock"
          })

        assert_validation_failure_resume!(validation_resume)

        {open_ui, client} = call_tool!(client, 450, "workflow_open_ui", %{"run_id" => run_id})
        assert_open_ui!(open_ui, run_id, scheduler_url)

        {shutdown, client} = request!(client, 451, "shutdown", %{})
        assert!(shutdown["result"] == %{}, "shutdown should return an empty result")
        await_port_exit!(client)
      end)

      assert_scheduler_stopped!(scheduler_url)
      IO.puts("MCP validate/start/status/inspect/resume/open-ui proof passed on #{scheduler_url}")
    after
      File.rm_rf(temp_root)
    end
  end

  defp reserve_port do
    {:ok, socket} =
      :gen_tcp.listen(0, [
        :binary,
        {:active, false},
        {:ip, {127, 0, 0, 1}},
        {:reuseaddr, true}
      ])

    {:ok, {{127, 0, 0, 1}, port}} = :inet.sockname(socket)
    :gen_tcp.close(socket)
    Integer.to_string(port)
  end

  defp mcp_env(port, journal_path) do
    [
      {~c"CODEX_LOOPS_SCHEDULER_URL", false},
      {~c"CODEX_LOOPS_SCHEDULER_BIN", false},
      {~c"CODEX_LOOPS_SCHEDULER_HOST", ~c"127.0.0.1"},
      {~c"CODEX_LOOPS_SCHEDULER_PORT", String.to_charlist(port)},
      {~c"CODEX_LOOPS_JOURNAL_PATH", String.to_charlist(journal_path)}
    ]
  end

  defp with_mcp_client(entrypoint, repo_root, env, fun) do
    client =
      %{
        port:
          Port.open({:spawn_executable, entrypoint}, [
            :binary,
            :exit_status,
            {:args, ["--stdio"]},
            {:cd, repo_root},
            {:env, env}
          ]),
        buffer: ""
      }

    try do
      fun.(client)
    after
      close_port(client.port)
    end
  end

  defp request!(client, id, method, params) do
    client =
      send_message!(client, %{
        "jsonrpc" => "2.0",
        "id" => id,
        "method" => method,
        "params" => params
      })

    await_response!(client, id)
  end

  defp notify!(client, method, params) do
    send_message!(client, %{"jsonrpc" => "2.0", "method" => method, "params" => params})
  end

  defp call_tool!(client, id, name, arguments) do
    request!(client, id, "tools/call", %{"name" => name, "arguments" => arguments})
  end

  defp send_message!(%{port: port} = client, message) do
    true = Port.command(port, Jason.encode!(message) <> "\n")
    client
  end

  defp await_response!(client, id) do
    deadline = System.monotonic_time(:millisecond) + @rpc_timeout_ms
    do_await_response!(client, id, deadline)
  end

  defp do_await_response!(client, id, deadline) do
    {message, client} = receive_message!(client, deadline)

    if message["id"] == id do
      {message, client}
    else
      do_await_response!(client, id, deadline)
    end
  end

  defp receive_message!(client, deadline) do
    case take_line(client.buffer) do
      {:ok, line, rest} ->
        {Jason.decode!(line), %{client | buffer: rest}}

      :more ->
        timeout = max(deadline - System.monotonic_time(:millisecond), 0)

        receive do
          {port, {:data, data}} when port == client.port ->
            receive_message!(%{client | buffer: client.buffer <> data}, deadline)

          {port, {:exit_status, status}} when port == client.port ->
            raise("MCP adapter exited before response with status #{status}")
        after
          timeout ->
            raise("timed out waiting for MCP response")
        end
    end
  end

  defp take_line(buffer) do
    case :binary.match(buffer, "\n") do
      {index, 1} ->
        <<line::binary-size(index), "\n", rest::binary>> = buffer

        case String.trim(line) do
          "" -> take_line(rest)
          trimmed -> {:ok, trimmed, rest}
        end

      :nomatch ->
        :more
    end
  end

  defp await_port_exit!(client) do
    receive do
      {port, {:exit_status, 0}} when port == client.port ->
        :ok

      {port, {:exit_status, status}} when port == client.port ->
        raise("MCP adapter exited with status #{status}")

      {port, {:data, data}} when port == client.port ->
        await_port_exit!(%{client | buffer: client.buffer <> data})
    after
      @rpc_timeout_ms ->
        raise("timed out waiting for MCP adapter to exit")
    end
  end

  defp close_port(port) do
    if Port.info(port) do
      Port.close(port)
    end
  rescue
    ArgumentError -> :ok
  end

  defp poll_completed_status!(client, run_id, next_id) do
    do_poll_completed_status!(client, run_id, next_id, @poll_attempts, nil)
  end

  defp poll_terminal_status!(client, run_id, next_id) do
    do_poll_terminal_status!(client, run_id, next_id, @poll_attempts, nil)
  end

  defp do_poll_completed_status!(_client, run_id, _next_id, 0, last_payload) do
    raise("run #{run_id} did not complete; last status: #{inspect(last_payload)}")
  end

  defp do_poll_completed_status!(client, run_id, next_id, attempts_left, _last_payload) do
    {response, client} = call_tool!(client, next_id, "workflow_status", %{"run_id" => run_id})
    payload = successful_tool_payload!(response, "workflow_status")
    state = get_in(payload, ["data", "state"])

    cond do
      state == "completed" ->
        {client, payload}

      state in ["failed", "killed"] ->
        raise("run #{run_id} reached terminal state #{state}: #{inspect(payload)}")

      true ->
        Process.sleep(@poll_interval_ms)
        do_poll_completed_status!(client, run_id, next_id + 1, attempts_left - 1, payload)
    end
  end

  defp do_poll_terminal_status!(_client, run_id, _next_id, 0, last_payload) do
    raise("run #{run_id} did not reach a terminal state; last status: #{inspect(last_payload)}")
  end

  defp do_poll_terminal_status!(client, run_id, next_id, attempts_left, _last_payload) do
    {response, client} = call_tool!(client, next_id, "workflow_status", %{"run_id" => run_id})
    payload = successful_tool_payload!(response, "workflow_status")
    state = get_in(payload, ["data", "state"])

    if state in ["completed", "failed"] do
      {client, payload}
    else
      Process.sleep(@poll_interval_ms)
      do_poll_terminal_status!(client, run_id, next_id + 1, attempts_left - 1, payload)
    end
  end

  defp workflow_source do
    """
    defmodule MCPLifecycleProofWorkflow do
      use Workflow

      workflow "mcp-lifecycle-proof" do
        phase "proof"
        log "mcp lifecycle proof"
        agent "Reply with proof-ok"
        return :ok
      end
    end
    """
  end

  defp running_workflow_source do
    agents =
      1..750
      |> Enum.map_join("\n", fn index ->
        ~s|        agent "keep lease #{index}"|
      end)

    """
    defmodule MCPRunningProofWorkflow do
      use Workflow

      workflow "mcp-running-proof" do
        #{agents}
        return :ok
      end
    end
    """
  end

  defp invalid_workflow_source do
    """
    defmodule MCPInvalidProofWorkflow do
      use Workflow

      workflow "mcp-invalid-proof" do
        frobnicate "nope"
      end
    end
    """
  end

  defp assert_initialize!(%{"result" => %{"serverInfo" => %{"name" => "codex-loops"}}}), do: :ok

  defp assert_initialize!(message),
    do: raise("initialize response was not valid: #{inspect(message)}")

  defp assert_tools_list!(%{"result" => %{"tools" => tools}}) when is_list(tools) do
    names = Enum.map(tools, & &1["name"])

    for name <- [
          "workflow_validate",
          "workflow_start",
          "workflow_status",
          "workflow_inspect",
          "workflow_resume",
          "workflow_open_ui"
        ] do
      assert!(name in names, "tools/list should include #{name}; got #{inspect(names)}")
    end
  end

  defp assert_tools_list!(message),
    do: raise("tools/list response was not valid: #{inspect(message)}")

  defp assert_successful_validation!(response, workflow_path) do
    payload = successful_tool_payload!(response, "workflow_validate")

    assert!(
      payload["api_version"] == "scheduler.v1",
      "valid workflow should return scheduler envelope"
    )

    assert!(payload["data"]["valid"] == true, "valid workflow should be valid")

    assert!(
      payload["data"]["workflow_name"] == "mcp-lifecycle-proof",
      "workflow name should be preserved"
    )

    assert!(payload["data"]["script"]["path"] == workflow_path, "script path should be preserved")
  end

  defp assert_missing_script_validation!(response, missing_path) do
    payload = error_tool_payload!(response, "workflow_validate")

    assert!(
      payload["api_version"] == "scheduler.v1",
      "missing workflow should return scheduler envelope"
    )

    assert!(
      payload["error"]["code"] == "scheduler.validation.script_not_found",
      "missing workflow should preserve typed scheduler error"
    )

    assert!(
      payload["error"]["details"]["path"] == missing_path,
      "missing path should be preserved"
    )
  end

  defp assert_started_run!(response, run_id) do
    payload = successful_tool_payload!(response, "workflow_start")

    assert!(
      payload["api_version"] == "scheduler.v1",
      "workflow_start should return scheduler envelope"
    )

    assert!(payload["data"]["run_id"] == run_id, "workflow_start should preserve run id")
    assert!(payload["data"]["state"] == "accepted", "workflow_start should accept the run")
    assert!(payload["data"]["ui_path"] == "/runs/#{run_id}", "ui_path should point at run")
    assert!(payload["data"]["ui_url"] == "/runs/#{run_id}", "ui_url should point at run")
  end

  defp assert_resumed_run!(response, run_id) do
    payload = successful_tool_payload!(response, "workflow_resume")

    assert!(
      payload["api_version"] == "scheduler.v1",
      "workflow_resume should return scheduler envelope"
    )

    assert!(payload["data"]["run_id"] == run_id, "workflow_resume should preserve run id")
    assert!(payload["data"]["state"] == "accepted", "workflow_resume should accept the run")
    assert!(payload["data"]["ui_path"] == "/runs/#{run_id}", "resume ui_path should point at run")
    assert!(payload["data"]["ui_url"] == "/runs/#{run_id}", "resume ui_url should point at run")
  end

  defp assert_completed_status!(payload, run_id) do
    assert!(
      payload["api_version"] == "scheduler.v1",
      "workflow_status should return scheduler envelope"
    )

    data = payload["data"]

    assert!(data["run_id"] == run_id, "workflow_status should preserve run id")
    assert!(data["state"] == "completed", "workflow_status should report completion")
    assert!(data["workflow_name"] == "mcp-lifecycle-proof", "workflow name should be projected")
    assert!(data["phase"] == "proof", "phase should be projected")
    assert!(data["logs"] == ["mcp lifecycle proof"], "logs should be projected")
    assert!(data["agent_count"] == 1, "agent_count should be projected")
    assert!(data["event_count"] == 5, "event_count should be projected")
    assert!(data["result"] == "ok", "result should be projected")
    assert!(data["failure"] == nil, "failure should be nil for successful run")
    assert!(data["ui_path"] == "/runs/#{run_id}", "status should include ui_path")
    assert!(data["ui_url"] == "/runs/#{run_id}", "status should include ui_url")

    assert!(
      data["usage"] == %{"input_tokens" => 0, "output_tokens" => 0, "total_tokens" => 0},
      "usage should be projected"
    )
  end

  defp assert_inspected_events!(response, run_id) do
    payload = successful_tool_payload!(response, "workflow_inspect")

    assert!(
      payload["api_version"] == "scheduler.v1",
      "workflow_inspect should return scheduler envelope"
    )

    assert!(payload["data"]["run_id"] == run_id, "workflow_inspect should preserve run id")

    events = payload["data"]["events"]
    assert!(Enum.map(events, & &1["seq"]) == [0, 1, 2, 3, 4], "events should be ordered")

    assert!(
      Enum.map(events, & &1["type"]) == [
        "run_started",
        "phase_entered",
        "log_emitted",
        "agent_committed",
        "run_completed"
      ],
      "events should preserve scheduler event types"
    )

    expected_events = [
      %{"seq" => 0, "type" => "run_started"},
      %{"seq" => 1, "type" => "phase_entered", "address" => [0]},
      %{"seq" => 2, "type" => "log_emitted", "address" => [1]},
      %{"seq" => 3, "type" => "agent_committed", "address" => [2]},
      %{"seq" => 4, "type" => "run_completed"}
    ]

    assert!(
      events == expected_events,
      "workflow_inspect should return MCP-friendly event projections"
    )

    inspector = payload["data"]["inspector"]

    assert!(inspector["run_id"] == run_id, "workflow_inspect inspector should preserve run id")
    assert!(inspector["event_count"] == 5, "workflow_inspect inspector should count events")
    assert!(inspector["failure"] == nil, "workflow_inspect inspector should omit failure")

    assert!(
      inspector["usage"] == %{"input_tokens" => 0, "output_tokens" => 0, "total_tokens" => 0},
      "workflow_inspect inspector should project usage"
    )

    assert!(
      Enum.map(inspector["phases"], & &1["name"]) == ["proof"],
      "workflow_inspect inspector should project phases"
    )

    assert!(
      inspector["agents"] == [
        %{
          "id" => "agent-2-i0",
          "slug" => "reply-with-proof-ok-i0",
          "address" => [2],
          "iteration" => 0,
          "prompt" => "Reply with proof-ok",
          "outcome" => %{"echo" => "Reply with proof-ok"},
          "result" => %{"echo" => "Reply with proof-ok"},
          "usage" => %{"input_tokens" => 0, "output_tokens" => 0, "total_tokens" => 0},
          "idempotency_key" => %{
            "run_id" => run_id,
            "node_path" => [2],
            "iteration" => 0,
            "attempt" => 0
          },
          "activity" => [],
          "phase_id" => "phase-0",
          "phase_name" => "proof"
        }
      ],
      "workflow_inspect inspector should project agent details"
    )

    assert!(
      inspector["rejected_attempts"] == [] and inspector["failed_rejected_attempts"] == [],
      "workflow_inspect inspector should expose empty rejection lists"
    )
  end

  defp assert_unknown_run_error!(response, tool_name, run_id) do
    payload = error_tool_payload!(response, tool_name)

    assert!(
      payload["api_version"] == "scheduler.v1",
      "#{tool_name} should return scheduler envelope"
    )

    assert!(
      payload["error"]["code"] == "scheduler.run.not_found",
      "#{tool_name} should preserve unknown-run scheduler error"
    )

    assert!(
      payload["error"]["details"]["run_id"] == run_id,
      "#{tool_name} should preserve unknown run id"
    )
  end

  defp assert_missing_script_resume!(response, missing_path) do
    payload = error_tool_payload!(response, "workflow_resume")

    assert!(
      payload["api_version"] == "scheduler.v1",
      "missing resume script should return scheduler envelope"
    )

    assert!(
      payload["error"]["code"] == "scheduler.validation.script_not_found",
      "missing resume script should preserve typed scheduler error"
    )

    assert!(
      payload["error"]["details"]["path"] == missing_path,
      "missing resume script path should be preserved"
    )
  end

  defp assert_validation_failure_resume!(response) do
    payload = error_tool_payload!(response, "workflow_resume")

    assert!(
      payload["api_version"] == "scheduler.v1",
      "invalid resume script should return scheduler envelope"
    )

    assert!(
      payload["error"]["code"] == "scheduler.validation.workflow_dsl",
      "invalid resume script should preserve typed scheduler validation error"
    )

    assert!(
      payload["error"]["details"]["reason"] =~ "unknown combinator `frobnicate`",
      "invalid resume script should preserve validation details"
    )
  end

  defp assert_already_running_resume!(response, run_id) do
    payload = error_tool_payload!(response, "workflow_resume")

    assert!(
      payload["api_version"] == "scheduler.v1",
      "already-running resume should return scheduler envelope"
    )

    assert!(
      payload["error"]["code"] == "scheduler.run.already_running",
      "already-running resume should preserve typed scheduler error"
    )

    assert!(
      payload["error"]["details"]["run_id"] == run_id,
      "already-running resume should preserve run id"
    )
  end

  defp assert_open_ui!(response, run_id, scheduler_url) do
    payload = successful_tool_payload!(response, "workflow_open_ui")

    assert!(
      payload["api_version"] == "codex-loops.mcp.v1",
      "workflow_open_ui should return MCP envelope"
    )

    data = payload["data"]

    assert!(data["run_id"] == run_id, "workflow_open_ui should preserve run id")
    assert!(data["state"] == "completed", "workflow_open_ui should include status projection")
    assert!(data["result"] == "ok", "workflow_open_ui should include result")
    assert!(data["failure"] == nil, "workflow_open_ui should include failure")

    assert!(
      data["usage"] == %{"input_tokens" => 0, "output_tokens" => 0, "total_tokens" => 0},
      "workflow_open_ui should include usage"
    )

    assert!(data["ui_path"] == "/runs/#{run_id}", "workflow_open_ui should include ui_path")
    assert!(data["ui_url"] == "/runs/#{run_id}", "workflow_open_ui should include ui_url")

    assert!(
      data["open_url"] == "#{scheduler_url}/runs/#{run_id}",
      "workflow_open_ui should include absolute open_url"
    )
  end

  defp successful_tool_payload!(%{"result" => result}, tool_name) do
    assert!(result["isError"] == false, "#{tool_name} should not be an MCP error")
    result["structuredContent"]
  end

  defp successful_tool_payload!(message, tool_name),
    do: raise("#{tool_name} success response was not valid: #{inspect(message)}")

  defp error_tool_payload!(%{"result" => result}, tool_name) do
    assert!(result["isError"] == true, "#{tool_name} should be an MCP error")
    result["structuredContent"]
  end

  defp error_tool_payload!(message, tool_name),
    do: raise("#{tool_name} error response was not valid: #{inspect(message)}")

  defp assert_scheduler_stopped!(scheduler_url) do
    {:ok, _apps} = Application.ensure_all_started(:inets)

    stopped? =
      Enum.reduce_while(1..50, false, fn _attempt, _acc ->
        case http_health(scheduler_url) do
          {:error, _reason} ->
            {:halt, true}

          {:ok, _response} ->
            Process.sleep(100)
            {:cont, false}
        end
      end)

    assert!(stopped?, "scheduler still responded at #{scheduler_url} after MCP shutdown")
  end

  defp http_health(scheduler_url) do
    :httpc.request(
      :get,
      {String.to_charlist(scheduler_url <> "/api/health"), []},
      [timeout: @http_timeout_ms, connect_timeout: @http_timeout_ms],
      body_format: :binary
    )
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
