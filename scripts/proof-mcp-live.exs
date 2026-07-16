defmodule ProofMCPLive do
  @moduledoc false

  @protocol_version "2025-11-25"
  @http_timeout_ms 30_000
  @startup_timeout_ms 20_000
  @shutdown_timeout_ms 15_000
  @poll_attempts 180
  @poll_interval_ms 1_000
  @max_response_bytes 8 * 1_024 * 1_024
  @max_release_log_bytes 1 * 1_024 * 1_024

  def run do
    codex_path =
      System.find_executable("codex") ||
        abort!("""
        Missing Codex CLI: `codex` was not found on PATH.

        Install and authenticate the Codex CLI, then rerun `make proof-mcp-live`.
        This manual proof spends one real Codex provider turn.
        """)

    {:ok, _apps} = Application.ensure_all_started(:inets)
    previous_trap_exit = Process.flag(:trap_exit, true)
    repo_root = Path.expand("..", __DIR__)
    temp_root = make_temp_root("codex-loops-mcp-live-proof")
    port = proof_port!()
    scheduler_url = "http://127.0.0.1:#{port}"

    packaged_release =
      Path.join(repo_root, "_build/dev-bundle/libexec/scheduler/bin/codex-loops-server")

    package_version = package_version(repo_root)

    assert!(
      executable_file?(packaged_release),
      "development bundle should include the packaged OTP scheduler release"
    )

    binding = prepare_live_binding!(temp_root, codex_path)
    workflow_path = Path.join(temp_root, "live-workflow.exs")
    journal_path = Path.join(temp_root, "runs.sqlite")
    run_id = "mcp:live_proof_#{System.unique_integer([:positive])}"
    codex_home = System.get_env("CODEX_HOME") || Path.join(System.user_home!(), ".codex")
    File.write!(workflow_path, workflow_source())

    IO.puts("Codex CLI: #{codex_path}")
    IO.puts("This manual proof spends one real Codex provider turn through Streamable HTTP MCP.")
    IO.puts("workflow=#{workflow_path}")
    IO.puts("journal=#{journal_path}")
    IO.puts("run_id=#{run_id}")

    try do
      release =
        start_release!(
          packaged_release,
          temp_root,
          release_env(temp_root, journal_path, port, binding, codex_home)
        )

      try do
        release = wait_for_healthy!(release, scheduler_url, package_version)
        initialize!(scheduler_url, package_version)
        assert_tools_list!(rpc!(scheduler_url, "tools/list", %{}))

        validation =
          call_tool!(scheduler_url, "workflow_validate", %{
            "script_path" => workflow_path,
            "workspace_root" => temp_root
          })

        assert_successful_validation!(validation, workflow_path)

        start =
          call_tool!(scheduler_url, "workflow_start", %{
            "script_path" => workflow_path,
            "workspace_root" => temp_root,
            "run_id" => run_id,
            "provider" => "codex"
          })

        assert_started_run!(start, run_id)
        status = poll_completed_status!(scheduler_url, run_id)
        assert_completed_status_with_usage!(status, run_id)

        resume =
          call_tool!(scheduler_url, "workflow_resume", %{
            "run_id" => run_id,
            "script_path" => workflow_path,
            "workspace_root" => temp_root,
            "provider" => "codex"
          })

        assert_started_run!(resume, run_id)
        resumed_status = poll_completed_status!(scheduler_url, run_id)
        assert_completed_status_with_usage!(resumed_status, run_id)

        assert!(
          get_in(resumed_status, ["data", "usage", "totalTokens"]) ==
            get_in(status, ["data", "usage", "totalTokens"]),
          "completed resume should not spend another Codex turn"
        )

        inspection = call_tool!(scheduler_url, "workflow_inspect", %{"run_id" => run_id})
        assert_inspected_live_events!(inspection, run_id)

        open_ui = call_tool!(scheduler_url, "workflow_open_ui", %{"run_id" => run_id})
        assert_open_ui!(open_ui, run_id, scheduler_url)

        assert!(File.regular?(journal_path), "live proof should persist its isolated journal")
        assert!(File.regular?(binding.path), "live proof should use its isolated Codex binding")
        assert_release_alive!(release, "scheduler should remain alive until explicit shutdown")

        stop_release!(release)
        assert_scheduler_stopped!(scheduler_url)
        IO.puts("Live Codex Streamable HTTP MCP proof passed on #{scheduler_url}")
      after
        stop_release(release)
      end
    after
      Process.flag(:trap_exit, previous_trap_exit)
      File.rm_rf(temp_root)
    end
  end

  defp initialize!(scheduler_url, package_version) do
    message = %{
      "jsonrpc" => "2.0",
      "id" => request_id(),
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => @protocol_version,
        "capabilities" => %{},
        "clientInfo" => %{"name" => "proof-mcp-live", "version" => package_version}
      }
    }

    response = post_mcp!(scheduler_url, Jason.encode!(message), protocol_version: nil)
    assert!(response.status == 200, "initialize should return HTTP 200: #{inspect(response)}")
    body = json_body!(response)

    assert!(
      get_in(body, ["result", "protocolVersion"]) == @protocol_version,
      "initialize should negotiate #{@protocol_version}"
    )

    assert!(
      get_in(body, ["result", "serverInfo", "name"]) == "codex-loops" and
        get_in(body, ["result", "serverInfo", "version"]) == package_version,
      "initialize should identify the packaged scheduler version"
    )

    notification = %{
      "jsonrpc" => "2.0",
      "method" => "notifications/initialized",
      "params" => %{}
    }

    notification_response = post_mcp!(scheduler_url, Jason.encode!(notification))
    assert!(notification_response.status == 202, "initialized notification should return HTTP 202")
  end

  defp poll_completed_status!(scheduler_url, run_id) do
    do_poll_completed_status!(scheduler_url, run_id, @poll_attempts, nil)
  end

  defp do_poll_completed_status!(scheduler_url, run_id, 0, last_payload) do
    inspection = diagnostic_inspection(scheduler_url, run_id)

    raise("""
    Timed out waiting for live Codex MCP run #{run_id} to complete.

    Last workflow_status payload:
    #{Jason.encode!(last_payload, pretty: true)}

    workflow_inspect payload:
    #{Jason.encode!(inspection, pretty: true)}

    Actionable checks:
    - Confirm `codex` is logged in and can run non-interactively.
    - Confirm the temporary workflow workspace is allowed for Codex CLI execution.
    - Rerun `make proof-mcp-live` only when spending another real Codex turn is acceptable.
    """)
  end

  defp do_poll_completed_status!(scheduler_url, run_id, attempts_left, _last_payload) do
    response = call_tool!(scheduler_url, "workflow_status", %{"run_id" => run_id})
    payload = successful_tool_payload!(response, "workflow_status")
    state = get_in(payload, ["data", "state"])

    case state do
      "completed" ->
        payload

      terminal when terminal in ["failed", "killed"] ->
        raise_live_failure!(run_id, terminal, payload)

      _nonterminal ->
        Process.sleep(@poll_interval_ms)
        do_poll_completed_status!(scheduler_url, run_id, attempts_left - 1, payload)
    end
  end

  defp diagnostic_inspection(scheduler_url, run_id) do
    message = %{
      "jsonrpc" => "2.0",
      "id" => request_id(),
      "method" => "tools/call",
      "params" => %{"name" => "workflow_inspect", "arguments" => %{"run_id" => run_id}}
    }

    with {:ok, %{status: 200} = response} <- post_mcp(scheduler_url, Jason.encode!(message)),
         {:ok, body} <- json_body(response),
         %{"result" => %{"structuredContent" => inspection}} <- body do
      inspection
    else
      {:ok, %{status: status, body: body}} ->
        %{"inspect_error" => "HTTP #{status}: #{inspect(body)}"}

      {:error, reason} ->
        %{"inspect_error" => inspect(reason)}

      unexpected_body ->
        %{"inspect_error" => "unexpected response: #{inspect(unexpected_body)}"}
    end
  end

  defp raise_live_failure!(run_id, state, payload) do
    raise("""
    Live Codex MCP run #{run_id} reached terminal state #{state}.

    workflow_status payload:
    #{Jason.encode!(payload, pretty: true)}

    Actionable checks:
    - Confirm `codex` is installed, logged in, and configured for this workspace.
    - Inspect the failure reason above; provider failures usually come from Codex CLI auth or configuration.
    - Rerun `make proof-mcp-live` only when spending another real Codex turn is acceptable.
    """)
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

    start = Enum.find(tools, &(&1["name"] == "workflow_start"))

    assert!(
      get_in(start, ["inputSchema", "properties", "provider", "enum"]) == ["mock", "codex"],
      "workflow_start should advertise mock and codex providers"
    )
  end

  defp assert_tools_list!(message), do: raise("tools/list response was not valid: #{inspect(message)}")

  defp assert_successful_validation!(response, workflow_path) do
    payload = successful_tool_payload!(response, "workflow_validate")
    data = payload["data"]

    assert!(payload["api_version"] == "scheduler.v1", "validation should use scheduler.v1")
    assert!(data["valid"] == true, "live workflow should validate")
    assert!(data["workflow_name"] == "mcp-live-proof", "workflow name should be preserved")
    assert!(data["script"]["path"] == workflow_path, "canonical workflow path should be preserved")
  end

  defp assert_started_run!(response, run_id) do
    payload = successful_tool_payload!(response, "workflow_start")
    data = payload["data"]

    assert!(payload["api_version"] == "scheduler.v1", "workflow_start should use scheduler.v1")
    assert!(data["run_id"] == run_id, "workflow_start should preserve run id")
    assert!(data["state"] == "accepted", "workflow_start should accept the run")
  end

  defp assert_completed_status_with_usage!(payload, run_id) do
    data = payload["data"]

    assert!(payload["api_version"] == "scheduler.v1", "workflow_status should use scheduler.v1")
    assert!(data["runId"] == run_id, "workflow_status should preserve run id")
    assert!(data["state"] == "completed", "workflow_status should report completion")
    assert!(data["treeName"] == "mcp-live-proof", "workflow name should be projected")
    assert!(data["result"] == "ok", "workflow result should be projected")
    assert!(data["failure"] == nil, "successful live run should not contain a failure")
    assert!(data["usage"]["totalTokens"] > 0, "journal-backed Codex usage should be nonzero")
  end

  defp assert_inspected_live_events!(response, run_id) do
    payload = successful_tool_payload!(response, "workflow_inspect")
    data = payload["data"]
    event_types = Enum.map(get_in(data, ["rawRefs", "journal"]), & &1["type"])

    activity_positions =
      event_types
      |> Enum.with_index()
      |> Enum.filter(fn {type, _index} -> type == "agent_activity" end)
      |> Enum.map(&elem(&1, 1))

    committed_position = Enum.find_index(event_types, &(&1 == "agent_committed"))

    assert!(data["runId"] == run_id, "workflow_inspect should preserve run id")
    assert!(activity_positions != [], "live proof should persist streamed Codex activity")

    assert!(
      is_integer(committed_position) and Enum.all?(activity_positions, &(&1 < committed_position)),
      "streamed Codex activity should be journaled before agent settlement"
    )

    assert!("run_completed" in event_types, "live proof should journal run completion")
  end

  defp assert_open_ui!(response, run_id, scheduler_url) do
    payload = successful_tool_payload!(response, "workflow_open_ui")
    data = payload["data"]

    assert!(payload["api_version"] == "codex-loops.mcp.v1", "open UI should use the MCP envelope")
    assert!(data["runId"] == run_id, "open UI should preserve run id")
    assert!(data["open_url"] == "#{scheduler_url}/runs/#{run_id}", "open UI should return an absolute URL")
  end

  defp successful_tool_payload!(%{"result" => result}, tool_name) do
    assert!(result["isError"] == false, "#{tool_name} should not be an MCP error: #{inspect(result)}")

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

  defp successful_tool_payload!(message, tool_name),
    do: raise("#{tool_name} success response was not valid: #{inspect(message)}")

  defp call_tool!(scheduler_url, name, arguments) do
    rpc!(scheduler_url, "tools/call", %{"name" => name, "arguments" => arguments})
  end

  defp rpc!(scheduler_url, method, params) do
    message = %{
      "jsonrpc" => "2.0",
      "id" => request_id(),
      "method" => method,
      "params" => params
    }

    response = post_mcp!(scheduler_url, Jason.encode!(message))
    assert!(response.status == 200, "#{method} should return HTTP 200: #{inspect(response)}")
    json_body!(response)
  end

  defp request_id, do: System.unique_integer([:positive, :monotonic])

  defp post_mcp!(scheduler_url, body, opts \\ []) do
    case post_mcp(scheduler_url, body, opts) do
      {:ok, response} -> response
      {:error, reason} -> raise("HTTP POST #{scheduler_url}/mcp failed: #{inspect(reason)}")
    end
  end

  defp post_mcp(scheduler_url, body, opts \\ []) do
    protocol_version = Keyword.get(opts, :protocol_version, @protocol_version)

    headers = maybe_header([{"accept", "application/json, text/event-stream"}], "mcp-protocol-version", protocol_version)

    http_request(:post, scheduler_url <> "/mcp", headers, {"application/json", body})
  end

  defp maybe_header(headers, _name, nil), do: headers
  defp maybe_header(headers, name, value), do: [{name, value} | headers]

  defp json_body(response) do
    case response do
      %{body: body} when byte_size(body) > 0 -> Jason.decode(body)
      _response -> {:error, :empty_json_body}
    end
  end

  defp json_body!(response) do
    case json_body(response) do
      {:ok, value} -> value
      {:error, reason} -> raise("HTTP response was not JSON: #{inspect(reason)} response=#{inspect(response)}")
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

  defp release_env(temp_root, journal_path, port, binding, codex_home) do
    [
      {"CODEX_LOOPS_SERVER", "1"},
      {"CODEX_LOOPS_HOST", "127.0.0.1"},
      {"CODEX_LOOPS_PORT", Integer.to_string(port)},
      {"PORT", Integer.to_string(port)},
      {"CODEX_LOOPS_JOURNAL_PATH", journal_path},
      {"CODEX_LOOPS_CODEX_BIN", binding.codex_path},
      {"CODEX_LOOPS_BINDING_PATH", binding.path},
      {"CODEX_LOOPS_CODEX_MODEL", System.get_env("CODEX_LOOPS_CODEX_MODEL") || false},
      {"CODEX_LOOPS_CODEX_SANDBOX", false},
      {"CODEX_LOOPS_CODEX_WORKDIR", false},
      {"CODEX_HOME", codex_home},
      {"HOME", System.user_home!()},
      {"RELEASE_DISTRIBUTION", "none"},
      {"RELEASE_NODE", "codex_loops_mcp_live_#{System.unique_integer([:positive])}"},
      {"RELEASE_TMP", Path.join(temp_root, "release-tmp")}
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
          Process.sleep(100)
          do_wait_for_healthy!(release, scheduler_url, package_version, deadline, result)
        else
          raise(
            "packaged scheduler did not become healthy: #{inspect(last_error || result)}\n" <>
              release_log(release)
          )
        end
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
          Process.sleep(100)
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

  defp prepare_live_binding!(temp_root, codex_path) do
    version = probe_codex_version!(codex_path)
    binding_path = Path.join(temp_root, "codex-binding.json")

    File.write!(
      binding_path,
      Jason.encode!(%{"path" => codex_path, "version" => version}, pretty: true)
    )

    %{path: binding_path, codex_path: codex_path}
  end

  defp probe_codex_version!(codex_path) do
    case Workflow.Install.Command.run(codex_path, ["--version"],
           timeout: 5_000,
           max_output_bytes: 16_384
         ) do
      {:ok, %{status: 0, output: output}} ->
        version = String.trim(output)

        if String.starts_with?(version, "codex-cli ") do
          version
        else
          abort!("`codex --version` returned an unsupported value: #{inspect(version)}")
        end

      {:ok, %{status: status, output: output}} ->
        abort!("`codex --version` failed with status #{status}: #{String.trim(output)}")

      {:error, reason} ->
        abort!("could not run `codex --version`: #{inspect(reason)}")
    end
  end

  defp workflow_source do
    """
    workflow "mcp-live-proof" do
      phase "prove live Codex through Streamable HTTP MCP"
      log "live MCP proof started"
      pipeline ["only"], [agent("Reply with exactly LIVE-MCP-PROOF-OK and no other text.")]
      return :ok
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
      _ -> abort!("CODEX_LOOPS_MCP_PROOF_PORT must be an integer from 1 to 65535")
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

  defp abort!(message) do
    IO.puts(:stderr, String.trim(message))
    System.halt(4)
  end
end

ProofMCPLive.run()
