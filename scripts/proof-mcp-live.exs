defmodule ProofMCPLive do
  @moduledoc false

  @http_timeout_ms 500
  @poll_attempts 180
  @poll_interval_ms 1_000
  @rpc_timeout_ms 30_000

  def run do
    codex_path =
      System.find_executable("codex") ||
        abort!("""
        Missing Codex CLI: `codex` was not found on PATH.

        Install and authenticate the Codex CLI, then rerun `make proof-mcp-live`.
        This proof spends a real Codex turn through the MCP scheduler path.
        """)

    repo_root = Path.expand("..", __DIR__)
    port = System.get_env("CODEX_LOOPS_MCP_PROOF_PORT") || reserve_port()

    temp_root = make_temp_root("codex-loops-mcp-live-proof")

    source_plugin_root = Path.join(repo_root, "plugins/codex-loops")
    installed_plugin_root = Path.join(temp_root, "installed-plugin/codex-loops")
    File.mkdir_p!(Path.dirname(installed_plugin_root))
    File.cp_r!(source_plugin_root, installed_plugin_root)

    entrypoint = Path.join(installed_plugin_root, "mcp/codex-loops-mcp")
    runtime_root = Path.join(repo_root, "_build/homebrew/libexec")
    packaged_scheduler = Path.join(runtime_root, "scheduler/bin/agent_loops")
    package_version = package_version(repo_root)

    assert!(
      executable_file?(entrypoint),
      "copied source plugin should include its MCP launcher"
    )

    assert!(
      executable_file?(packaged_scheduler),
      "staged Homebrew runtime should include scheduler release"
    )

    assert_mcp_version!(entrypoint, runtime_root, package_version)

    workflow_path = Path.join(temp_root, "live-workflow.exs")
    journal_path = Path.join(temp_root, "runs.sqlite")
    run_id = "mcp:live_proof_#{System.unique_integer([:positive])}"
    scheduler_url = "http://127.0.0.1:#{port}"

    IO.puts("Codex CLI: #{codex_path}")
    IO.puts("This proof spends one real Codex provider turn through MCP.")
    IO.puts("workflow=#{workflow_path}")
    IO.puts("journal=#{journal_path}")
    IO.puts("run_id=#{run_id}")

    try do
      File.write!(workflow_path, workflow_source())

      with_mcp_client(
        temp_root,
        entrypoint,
        repo_root,
        mcp_env(port, journal_path, codex_path, runtime_root),
        fn client ->
          {initialize, client} =
            request!(client, 1, "initialize", %{
              "protocolVersion" => "2024-11-05",
              "capabilities" => %{},
              "clientInfo" => %{"name" => "proof-mcp-live", "version" => "0.0.0"}
            })

          assert_initialize!(initialize, package_version)
          client = notify!(client, "notifications/initialized", %{})

          {tools, client} = request!(client, 2, "tools/list", %{})
          assert_tools_list!(tools)

          {validation, client} =
            call_tool!(client, 3, "workflow_validate", %{"script_path" => workflow_path})

          assert_successful_validation!(validation, workflow_path)

          {start, client} =
            call_tool!(client, 4, "workflow_start", %{
              "script_path" => workflow_path,
              "run_id" => run_id,
              "provider" => "codex"
            })

          assert_started_run!(start, run_id)

          {client, status_payload} = poll_completed_status!(client, run_id, 5)
          assert_completed_status_with_usage!(status_payload, run_id)

          {inspect, client} = call_tool!(client, 250, "workflow_inspect", %{"run_id" => run_id})
          assert_inspected_live_events!(inspect, run_id)

          client
          |> close_input!()
          |> await_port_exit!()
        end
      )

      assert_scheduler_stopped!(scheduler_url)
      IO.puts("MCP live Codex proof passed on #{scheduler_url}")
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

  defp mcp_env(port, journal_path, codex_path, runtime_root) do
    [
      {~c"CODEX_LOOPS_SCHEDULER_URL", false},
      {~c"CODEX_LOOPS_SCHEDULER_BIN", false},
      {~c"CODEX_LOOPS_RUNTIME_ROOT", String.to_charlist(runtime_root)},
      {~c"CODEX_LOOPS_SCHEDULER_HOST", ~c"127.0.0.1"},
      {~c"CODEX_LOOPS_SCHEDULER_PORT", String.to_charlist(port)},
      {~c"CODEX_LOOPS_JOURNAL_PATH", String.to_charlist(journal_path)},
      {~c"CODEX_LOOPS_CODEX_BIN", String.to_charlist(codex_path)},
      {~c"CODEX_LOOPS_CODEX_MODEL", ~c"gpt-5.5"},
      {~c"CODEX_LOOPS_PARENT_PATH", String.to_charlist(System.get_env("PATH") || "")},
      {~c"PATH", String.to_charlist(System.get_env("PATH") || "")}
    ]
  end

  defp with_mcp_client(temp_root, entrypoint, repo_root, env, fun) do
    fifo_path = Path.join(temp_root, "mcp-stdin")
    {_output, 0} = System.cmd("mkfifo", [fifo_path])

    port =
      Port.open({:spawn_executable, "/bin/sh"}, [
        :binary,
        :exit_status,
        {:args, ["-c", ~s(exec "$1" --stdio < "$2"), "codex-loops-mcp", entrypoint, fifo_path]},
        {:cd, repo_root},
        {:env, env}
      ])

    client =
      %{
        port: port,
        input: File.open!(fifo_path, [:write, :binary]),
        buffer: ""
      }

    try do
      fun.(client)
    after
      close_client(client)
      File.rm(fifo_path)
    end
  end

  defp make_temp_root(prefix) do
    path =
      Path.join(
        System.tmp_dir!(),
        "#{prefix}-#{System.system_time(:nanosecond)}-#{System.unique_integer([:positive])}"
      )

    File.mkdir!(path)
    path
  rescue
    _error in File.Error -> make_temp_root(prefix)
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

  defp send_message!(%{input: input} = client, message) do
    IO.write(input, Jason.encode!(message) <> "\n")
    client
  end

  defp close_input!(%{input: nil} = client), do: client

  defp close_input!(%{input: input} = client) do
    File.close(input)
    %{client | input: nil}
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
        try do
          {Jason.decode!(line), %{client | buffer: rest}}
        rescue
          Jason.DecodeError ->
            raise("MCP adapter emitted non-JSON stdout line: #{inspect(line)}")
        end

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

  defp close_client(client) do
    client = close_input!(client)

    if Port.info(client.port) do
      await_or_close_port(client.port)
    end
  rescue
    ArgumentError -> :ok
  end

  defp await_or_close_port(port) do
    receive do
      {^port, {:exit_status, _status}} ->
        :ok

      {^port, {:data, _data}} ->
        await_or_close_port(port)
    after
      5_000 ->
        Port.close(port)
    end
  end

  defp poll_completed_status!(client, run_id, next_id) do
    do_poll_completed_status!(client, run_id, next_id, @poll_attempts, nil)
  end

  defp do_poll_completed_status!(client, run_id, _next_id, 0, last_payload) do
    inspected =
      try do
        {response, _client} = call_tool!(client, 900, "workflow_inspect", %{"run_id" => run_id})
        response["result"] && response["result"]["structuredContent"]
      rescue
        error -> %{"inspect_error" => Exception.message(error)}
      end

    raise("""
    Timed out waiting for live Codex MCP run #{run_id} to complete.

    Last workflow_status payload:
    #{Jason.encode!(last_payload, pretty: true)}

    workflow_inspect payload:
    #{Jason.encode!(inspected, pretty: true)}

    Actionable checks:
    - Confirm `codex` is logged in and can run non-interactively.
    - Confirm this repo/workspace is allowed for Codex CLI execution.
    - Rerun `make proof-mcp-live` only when spending a real Codex turn is acceptable.
    """)
  end

  defp do_poll_completed_status!(client, run_id, next_id, attempts_left, _last_payload) do
    {response, client} = call_tool!(client, next_id, "workflow_status", %{"run_id" => run_id})
    payload = successful_tool_payload!(response, "workflow_status")
    state = get_in(payload, ["data", "state"])

    cond do
      state == "completed" ->
        {client, payload}

      state in ["failed", "killed"] ->
        raise_live_failure!(run_id, state, payload)

      true ->
        Process.sleep(@poll_interval_ms)
        do_poll_completed_status!(client, run_id, next_id + 1, attempts_left - 1, payload)
    end
  end

  defp raise_live_failure!(run_id, state, payload) do
    raise("""
    Live Codex MCP run #{run_id} reached terminal state #{state}.

    workflow_status payload:
    #{Jason.encode!(payload, pretty: true)}

    Actionable checks:
    - Confirm `codex` is installed, logged in, and configured for this workspace.
    - Inspect the failure reason above; provider failures usually come from Codex CLI auth/config or a failed live turn.
    - Rerun `make proof-mcp-live` only when spending another real Codex turn is acceptable.
    """)
  end

  defp workflow_source do
    """
    defmodule MCPLiveProofWorkflow do
      use Workflow

      workflow "mcp-live-proof" do
        phase "prove live Codex through MCP"
        log "live MCP proof started"
        agent "Reply with exactly LIVE-MCP-PROOF-OK and no other text."
        return :ok
      end
    end
    """
  end

  defp assert_initialize!(%{"result" => %{"serverInfo" => %{"name" => "codex-loops", "version" => version}}}, version),
    do: :ok

  defp assert_initialize!(message, _version), do: raise("initialize response was not valid: #{inspect(message)}")

  defp assert_mcp_version!(entrypoint, runtime_root, version) do
    expected = "codex-loops-mcp #{version}\n"

    case System.cmd(entrypoint, ["--version"],
           env: [{"CODEX_LOOPS_RUNTIME_ROOT", runtime_root}],
           stderr_to_stdout: true
         ) do
      {^expected, 0} ->
        :ok

      {output, status} ->
        raise("MCP --version failed with #{status}: #{inspect(output)}")
    end
  end

  defp package_version(repo_root) do
    repo_root
    |> Path.join("VERSION")
    |> File.read!()
    |> String.trim()
  end

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

    start_tool = Enum.find(tools, &(&1["name"] == "workflow_start"))
    providers = get_in(start_tool, ["inputSchema", "properties", "provider", "enum"])
    assert!(providers == ["mock", "codex"], "workflow_start should advertise mock and codex")
  end

  defp assert_tools_list!(message), do: raise("tools/list response was not valid: #{inspect(message)}")

  defp assert_successful_validation!(response, workflow_path) do
    payload = successful_tool_payload!(response, "workflow_validate")

    assert!(
      payload["api_version"] == "scheduler.v1",
      "validation should return scheduler envelope"
    )

    assert!(payload["data"]["valid"] == true, "valid workflow should be valid")

    assert!(
      payload["data"]["workflow_name"] == "mcp-live-proof",
      "workflow name should be preserved"
    )

    assert!(payload["data"]["script"]["path"] == workflow_path, "script path should be preserved")
  end

  defp assert_started_run!(response, run_id) do
    payload = successful_tool_payload!(response, "workflow_start")

    assert!(
      payload["api_version"] == "scheduler.v1",
      "workflow_start should return scheduler envelope"
    )

    assert!(payload["data"]["run_id"] == run_id, "workflow_start should preserve run id")
    assert!(payload["data"]["state"] == "accepted", "workflow_start should accept the run")
  end

  defp assert_completed_status_with_usage!(payload, run_id) do
    data = payload["data"]

    assert!(
      payload["api_version"] == "scheduler.v1",
      "workflow_status should return scheduler envelope"
    )

    assert!(data["runId"] == run_id, "workflow_status should preserve run id")
    assert!(data["state"] == "completed", "workflow_status should report completion")
    assert!(data["treeName"] == "mcp-live-proof", "workflow name should be projected")
    assert!(data["result"] == "ok", "result should be projected")
    assert!(data["failure"] == nil, "failure should be nil for successful run")
    assert!(data["usage"]["totalTokens"] > 0, "journal-backed usage should be nonzero")
  end

  defp assert_inspected_live_events!(response, run_id) do
    payload = successful_tool_payload!(response, "workflow_inspect")

    assert!(
      payload["api_version"] == "scheduler.v1",
      "workflow_inspect should return scheduler envelope"
    )

    data = payload["data"]

    assert!(data["runId"] == run_id, "workflow_inspect should preserve run id")

    event_types = Enum.map(get_in(data, ["rawRefs", "journal"]), & &1["type"])

    activity_positions =
      event_types
      |> Enum.with_index()
      |> Enum.filter(fn {type, _index} -> type == "agent_activity" end)
      |> Enum.map(&elem(&1, 1))

    committed_position = Enum.find_index(event_types, &(&1 == "agent_committed"))

    assert!(activity_positions != [], "live proof should persist streamed Codex activity")

    assert!(
      is_integer(committed_position) and Enum.all?(activity_positions, &(&1 < committed_position)),
      "streamed Codex activity should be journaled before agent settlement"
    )

    assert!("agent_committed" in event_types, "live proof should commit an agent result")
    assert!("run_completed" in event_types, "live proof should complete")
  end

  defp successful_tool_payload!(%{"result" => result}, tool_name) do
    assert!(result["isError"] == false, "#{tool_name} should not be an MCP error")
    result["structuredContent"]
  end

  defp successful_tool_payload!(message, tool_name),
    do: raise("#{tool_name} success response was not valid: #{inspect(message)}")

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

  defp abort!(message) do
    IO.puts(:stderr, String.trim(message))
    System.halt(4)
  end
end

ProofMCPLive.run()
