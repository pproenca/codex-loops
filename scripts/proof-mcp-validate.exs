defmodule ProofMCPValidate do
  @moduledoc false

  @http_timeout_ms 500
  @poll_attempts 100
  @poll_interval_ms 100
  @rpc_timeout_ms 15_000
  @conformance_workflows [
    %{
      file: "conformance_core.exs",
      name: "conformance-core",
      result: :ok,
      events:
        ~w(parallel_started pipeline_started verify_started judge_started loop_decision accumulate fanout_started fan_out_started run_completed)
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
    repo_root = Path.expand("..", __DIR__)
    port = System.get_env("CODEX_LOOPS_MCP_PROOF_PORT") || reserve_port()

    temp_root = make_temp_root("codex-loops-mcp-proof")

    source_plugin_root = Path.join(repo_root, "plugins/codex-loops")
    installed_plugin_root = Path.join(temp_root, "installed-plugin/codex-loops")
    File.mkdir_p!(Path.dirname(installed_plugin_root))
    File.cp_r!(source_plugin_root, installed_plugin_root)

    entrypoint = Path.join(installed_plugin_root, "mcp/codex-loops-mcp")
    runtime_root = Path.join(repo_root, "_build/homebrew/libexec")
    packaged_scheduler = Path.join(runtime_root, "scheduler/bin/agent_loops")
    codex_stub = Path.join(repo_root, "scripts/support/codex-conformance-stub.py")
    package_version = package_version(repo_root)

    assert!(
      executable_file?(entrypoint),
      "copied source plugin should include its MCP launcher"
    )

    assert!(
      executable_file?(packaged_scheduler),
      "staged Homebrew runtime should include scheduler release"
    )

    assert!(executable_file?(codex_stub), "Codex conformance stub should be executable")

    assert_missing_runtime!(entrypoint, temp_root)
    assert_version_mismatch!(entrypoint, temp_root, package_version)
    assert_mcp_version!(entrypoint, runtime_root, package_version)

    workflow_path = Path.join(temp_root, "workflow.exs")
    running_workflow_path = Path.join(temp_root, "running-workflow.exs")
    invalid_workflow_path = Path.join(temp_root, "invalid-workflow.exs")
    missing_path = Path.join(temp_root, "missing-workflow.exs")
    journal_path = Path.join(temp_root, "runs.sqlite")
    runtime_dir = Path.join(temp_root, "runtime")
    run_id = "mcp:proof_#{System.unique_integer([:positive])}"
    running_run_id = "mcp:proof_running_#{System.unique_integer([:positive])}"
    unknown_run_id = "mcp:proof_missing_#{System.unique_integer([:positive])}"
    scheduler_url = "http://127.0.0.1:#{port}"

    try do
      File.write!(workflow_path, workflow_source())
      File.write!(running_workflow_path, running_workflow_source())
      File.write!(invalid_workflow_path, invalid_workflow_source())

      with_mcp_client(
        temp_root,
        entrypoint,
        repo_root,
        mcp_env(port, journal_path, runtime_root, codex_stub),
        fn client ->
          {initialize, client} =
            request!(client, 1, "initialize", %{
              "protocolVersion" => "2024-11-05",
              "capabilities" => %{"roots" => %{}},
              "clientInfo" => %{"name" => "proof-mcp-validate", "version" => "0.0.0"}
            })

          assert_initialize!(initialize, package_version)
          client = notify!(client, "notifications/initialized", %{})

          {tools, client} = request!(client, 2, "tools/list", %{})
          assert_tools_list!(tools)

          {invalid_call, client} = call_tool!(client, 8_999, "workflow_start", %{})

          assert!(
            get_in(invalid_call, ["error", "code"]) == -32_602,
            "invalid MCP arguments should return JSON-RPC invalid params"
          )

          assert!(
            match?({:error, _reason}, http_health(scheduler_url)),
            "invalid MCP arguments must not start the scheduler"
          )

          relative_path = ".codex/workflows/conformance_core.exs"

          {relative_validation, client} =
            call_tool!(client, 9_000, "workflow_validate", %{"script_path" => relative_path})

          assert_successful_validation!(
            relative_validation,
            Path.join(repo_root, relative_path),
            "conformance-core"
          )

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

          client = prove_conformance_workflows!(client, repo_root)

          client
          |> close_input!()
          |> await_port_exit!()
        end
      )

      assert_scheduler_running!(scheduler_url)
      stop_scheduler!(runtime_root, runtime_dir, port)
      assert_scheduler_stopped!(scheduler_url)
      IO.puts("MCP validate/start/status/inspect/resume/open-ui proof passed on #{scheduler_url}")
    after
      stop_scheduler(runtime_root, runtime_dir, port)
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

  defp mcp_env(port, journal_path, runtime_root, codex_stub) do
    [
      {~c"CODEX_LOOPS_SCHEDULER_URL", false},
      {~c"CODEX_LOOPS_SCHEDULER_BIN", false},
      {~c"CODEX_LOOPS_RUNTIME_ROOT", String.to_charlist(runtime_root)},
      {~c"CODEX_LOOPS_RUNTIME_DIR", String.to_charlist(Path.join(Path.dirname(journal_path), "runtime"))},
      {~c"CODEX_LOOPS_SCHEDULER_HOST", ~c"127.0.0.1"},
      {~c"CODEX_LOOPS_SCHEDULER_PORT", String.to_charlist(port)},
      {~c"CODEX_LOOPS_JOURNAL_PATH", String.to_charlist(journal_path)},
      {~c"CODEX_LOOPS_CODEX_BIN", String.to_charlist(codex_stub)}
    ]
  end

  defp prove_conformance_workflows!(client, repo_root) do
    @conformance_workflows
    |> Enum.with_index()
    |> Enum.reduce(client, fn {workflow, index}, client ->
      request_base = 500 + index * 300
      path = Path.join([repo_root, ".codex", "workflows", workflow.file])
      run_id = "mcp:#{workflow.name}_#{System.unique_integer([:positive])}"

      {validation, client} =
        call_tool!(client, request_base, "workflow_validate", %{"script_path" => path})

      assert_successful_validation!(validation, path, workflow.name)

      {start, client} =
        call_tool!(client, request_base + 1, "workflow_start", %{
          "script_path" => path,
          "run_id" => run_id,
          "provider" => "codex",
          "budget" => 10_000
        })

      assert_started_run!(start, run_id)
      {client, status} = poll_completed_status!(client, run_id, request_base + 2)
      assert_conformance_status!(status, run_id, workflow.name, workflow.result)

      {inspection, client} =
        call_tool!(client, request_base + 200, "workflow_inspect", %{"run_id" => run_id})

      assert_conformance_events!(inspection, run_id, workflow.events)
      client
    end)
  end

  defp with_mcp_client(temp_root, entrypoint, repo_root, env, fun) do
    fifo_path = Path.join(temp_root, "mcp-stdin")
    {_output, 0} = System.cmd("mkfifo", [fifo_path])

    port =
      Port.open({:spawn_executable, "/bin/sh"}, [
        :binary,
        :exit_status,
        {:args, ["-c", ~s(exec "$1" --stdio < "$2"), "codex-loops-mcp", entrypoint, fifo_path]},
        {:cd, Path.dirname(Path.dirname(entrypoint))},
        {:env, env}
      ])

    client =
      %{
        port: port,
        input: File.open!(fifo_path, [:write, :binary]),
        buffer: "",
        workspace_root: repo_root
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
    canonical_path(path)
  rescue
    _error in File.Error -> make_temp_root(prefix)
  end

  defp canonical_path(path) do
    {resolved, 0} = System.cmd("realpath", [path])
    String.trim(resolved)
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

    cond do
      message["id"] == id ->
        {message, client}

      message["method"] == "roots/list" and not is_nil(message["id"]) ->
        client =
          send_message!(client, %{
            "jsonrpc" => "2.0",
            "id" => message["id"],
            "result" => %{
              "roots" => [%{"uri" => "file://#{client.workspace_root}", "name" => "workspace"}]
            }
          })

        do_await_response!(client, id, deadline)

      true ->
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
        assert!(
          String.trim(client.buffer) == "",
          "MCP adapter emitted trailing non-protocol stdout: #{inspect(client.buffer)}"
        )

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
      Enum.map_join(1..750, "\n", fn index ->
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

  defp assert_missing_runtime!(entrypoint, temp_root) do
    missing_root = Path.join(temp_root, "missing-runtime")

    case System.cmd(entrypoint, ["--version"],
           env: [
             {"CODEX_LOOPS_MCP_BIN", nil},
             {"CODEX_LOOPS_SCHEDULER_BIN", nil},
             {"CODEX_LOOPS_RUNTIME_ROOT", missing_root},
             {"PATH", "/usr/bin:/bin"}
           ],
           stderr_to_stdout: true
         ) do
      {output, 1} ->
        assert!(
          String.contains?(output, "does not contain a usable Codex Loops runtime") and
            String.contains?(output, "brew install pproenca/codex-loops/codex-loops"),
          "missing-runtime diagnostic was not actionable: #{inspect(output)}"
        )

      {output, status} ->
        raise("missing-runtime proof returned #{status}: #{inspect(output)}")
    end
  end

  defp assert_version_mismatch!(entrypoint, temp_root, version) do
    mismatch_root = Path.join(temp_root, "mismatched-runtime")
    mcp = Path.join(mismatch_root, "mcp/codex-loops-mcp")
    scheduler = Path.join(mismatch_root, "scheduler/bin/agent_loops")
    File.mkdir_p!(Path.dirname(mcp))
    File.mkdir_p!(Path.dirname(scheduler))
    File.write!(mcp, "#!/bin/sh\necho 'codex-loops-mcp 99.0.0'\n")
    File.write!(scheduler, "#!/bin/sh\nexit 0\n")
    File.chmod!(mcp, 0o755)
    File.chmod!(scheduler, 0o755)

    case System.cmd(entrypoint, ["--version"],
           env: [
             {"CODEX_LOOPS_MCP_BIN", nil},
             {"CODEX_LOOPS_SCHEDULER_BIN", nil},
             {"CODEX_LOOPS_RUNTIME_ROOT", mismatch_root}
           ],
           stderr_to_stdout: true
         ) do
      {output, 1} ->
        assert!(
          String.contains?(output, "plugin/runtime version mismatch") and
            String.contains?(output, "Plugin:  #{version}") and
            String.contains?(output, "Runtime: 99.0.0"),
          "version-mismatch diagnostic was not actionable: #{inspect(output)}"
        )

      {output, status} ->
        raise("version-mismatch proof returned #{status}: #{inspect(output)}")
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

    status_tool = Enum.find(tools, &(&1["name"] == "workflow_status"))
    inspect_tool = Enum.find(tools, &(&1["name"] == "workflow_inspect"))

    assert!(
      status_tool["description"] =~ "§7.5 status projection",
      "workflow_status metadata should describe the public §7.5 surface"
    )

    assert!(
      inspect_tool["description"] =~ "§7.5 inspect/status projection" and
        inspect_tool["description"] =~ "rawRefs",
      "workflow_inspect metadata should describe rawRefs-based public projection"
    )
  end

  defp assert_tools_list!(message), do: raise("tools/list response was not valid: #{inspect(message)}")

  defp assert_successful_validation!(response, workflow_path, workflow_name \\ "mcp-lifecycle-proof") do
    payload = successful_tool_payload!(response, "workflow_validate")

    assert!(
      payload["api_version"] == "scheduler.v1",
      "valid workflow should return scheduler envelope"
    )

    assert!(payload["data"]["valid"] == true, "valid workflow should be valid")

    assert!(
      payload["data"]["workflow_name"] == workflow_name,
      "workflow name should be preserved"
    )

    assert!(payload["data"]["script"]["path"] == workflow_path, "script path should be preserved")
  end

  defp assert_conformance_status!(payload, run_id, workflow_name, result_shape) do
    data = payload["data"]

    assert!(payload["api_version"] == "scheduler.v1", "conformance status should use scheduler envelope")
    assert!(data["runId"] == run_id, "conformance status should preserve run id")
    assert!(data["treeName"] == workflow_name, "conformance workflow name should be projected")
    assert!(data["state"] == "completed", "conformance workflow should complete")
    assert!(data["failure"] == nil, "conformance workflow should not fail")
    assert!(data["usage"]["totalTokens"] > 0, "conformance workflow should traverse the Codex provider port")
    assert_conformance_result!(data["result"], result_shape)
  end

  defp assert_conformance_result!("ok", :ok), do: :ok

  defp assert_conformance_result!(result, :dataflow) when is_binary(result) do
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

  defp assert_missing_script_validation!(response, missing_path) do
    payload = error_tool_payload!(response, "workflow_validate")

    assert!(
      payload["api_version"] == "codex-loops.mcp.v1",
      "missing workflow should return native MCP envelope"
    )

    assert!(
      payload["error"]["code"] == "script_not_found",
      "missing workflow should preserve typed native error"
    )

    assert!(
      payload["error"]["details"]["script_path"] == missing_path,
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

    assert!(data["runId"] == run_id, "workflow_status should preserve run id")
    assert!(data["state"] == "completed", "workflow_status should report completion")
    assert!(data["treeName"] == "mcp-lifecycle-proof", "workflow name should be projected")
    assert!(data["phase"] == "proof", "phase should be projected")
    assert!(data["logs"] == ["mcp lifecycle proof"], "logs should be projected")
    assert!(data["agentCount"] == 1, "agentCount should be projected")
    assert!(data["eventCount"] == 5, "eventCount should be projected")
    assert!(data["result"] == "ok", "result should be projected")
    assert!(data["failure"] == nil, "failure should be nil for successful run")

    assert!(
      data["usage"] == %{"inputTokens" => 0, "outputTokens" => 0, "totalTokens" => 0},
      "usage should be projected"
    )

    assert!(not Map.has_key?(data, "uiPath"), "workflow_status should be exact §7.5 data")
    assert!(not Map.has_key?(data, "events"), "workflow_status should not include events")
  end

  defp assert_inspected_events!(response, run_id) do
    payload = successful_tool_payload!(response, "workflow_inspect")

    assert!(
      payload["api_version"] == "scheduler.v1",
      "workflow_inspect should return scheduler envelope"
    )

    data = payload["data"]

    assert!(data["runId"] == run_id, "workflow_inspect should preserve run id")
    assert!(data["eventCount"] == 5, "workflow_inspect should project event count")
    assert!(not Map.has_key?(data, "events"), "workflow_inspect should expose §7.5 data")

    raw_refs = get_in(data, ["rawRefs", "journal"])
    assert!(Enum.map(raw_refs, & &1["seq"]) == [0, 1, 2, 3, 4], "raw refs should be ordered")

    assert!(
      Enum.map(raw_refs, & &1["type"]) == [
        "run_started",
        "phase_entered",
        "log_emitted",
        "agent_committed",
        "run_completed"
      ],
      "raw refs should preserve journal event types"
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
      payload["api_version"] == "codex-loops.mcp.v1",
      "missing resume script should return native MCP envelope"
    )

    assert!(
      payload["error"]["code"] == "script_not_found",
      "missing resume script should preserve typed native error"
    )

    assert!(
      payload["error"]["details"]["script_path"] == missing_path,
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
      "already-running resume should return scheduler envelope: #{inspect(payload)}"
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

    assert!(data["runId"] == run_id, "workflow_open_ui should preserve run id")
    assert!(data["state"] == "completed", "workflow_open_ui should include status projection")
    assert!(data["result"] == "ok", "workflow_open_ui should include result")
    assert!(data["failure"] == nil, "workflow_open_ui should include failure")

    assert!(
      data["usage"] == %{"inputTokens" => 0, "outputTokens" => 0, "totalTokens" => 0},
      "workflow_open_ui should include usage"
    )

    assert!(data["uiPath"] == "/runs/#{run_id}", "workflow_open_ui should include uiPath")
    assert!(data["uiUrl"] == "/runs/#{run_id}", "workflow_open_ui should include uiUrl")

    assert!(
      data["open_url"] == "#{scheduler_url}/runs/#{run_id}",
      "workflow_open_ui should include absolute open_url"
    )
  end

  defp successful_tool_payload!(%{"result" => result}, tool_name) do
    assert!(
      result["isError"] == false,
      "#{tool_name} should not be an MCP error: #{inspect(result)}"
    )

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

    assert!(stopped?, "scheduler still responded at #{scheduler_url} after explicit stop")
  end

  defp assert_scheduler_running!(scheduler_url) do
    assert!(
      match?({:ok, _response}, http_health(scheduler_url)),
      "scheduler should survive MCP shutdown at #{scheduler_url}"
    )
  end

  defp stop_scheduler!(runtime_root, runtime_dir, port) do
    {output, status} = stop_scheduler(runtime_root, runtime_dir, port)
    assert!(status == 0, "native CLI could not stop scheduler: #{output}")
  end

  defp stop_scheduler(runtime_root, runtime_dir, port) do
    cli = Path.join(runtime_root, "bin/codex-loops")

    System.cmd(cli, ["stop", "--host", "127.0.0.1", "--port", to_string(port), "--json"],
      env: [
        {"CODEX_LOOPS_RUNTIME_ROOT", runtime_root},
        {"CODEX_LOOPS_RUNTIME_DIR", runtime_dir},
        {"CODEX_LOOPS_SCHEDULER_HOST", "127.0.0.1"},
        {"CODEX_LOOPS_SCHEDULER_PORT", to_string(port)}
      ],
      stderr_to_stdout: true
    )
  rescue
    error -> {Exception.message(error), 1}
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
