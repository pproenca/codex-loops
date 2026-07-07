defmodule ProofMCPValidate do
  @moduledoc false

  @timeout_ms 500

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
    missing_path = Path.join(temp_root, "missing-workflow.exs")
    input_path = Path.join(temp_root, "requests.ndjson")
    journal_path = Path.join(temp_root, "runs.sqlite")
    scheduler_url = "http://127.0.0.1:#{port}"

    try do
      File.write!(workflow_path, workflow_source())

      env = [
        {"CODEX_LOOPS_SCHEDULER_HOST", "127.0.0.1"},
        {"CODEX_LOOPS_SCHEDULER_PORT", port},
        {"CODEX_LOOPS_JOURNAL_PATH", journal_path}
      ]

      input =
        [
          %{
            "jsonrpc" => "2.0",
            "id" => 1,
            "method" => "initialize",
            "params" => %{
              "protocolVersion" => "2024-11-05",
              "capabilities" => %{},
              "clientInfo" => %{"name" => "proof-mcp-validate", "version" => "0.0.0"}
            }
          },
          %{"jsonrpc" => "2.0", "method" => "notifications/initialized", "params" => %{}},
          %{"jsonrpc" => "2.0", "id" => 2, "method" => "tools/list", "params" => %{}},
          %{
            "jsonrpc" => "2.0",
            "id" => 3,
            "method" => "tools/call",
            "params" => %{
              "name" => "workflow_validate",
              "arguments" => %{"script_path" => workflow_path}
            }
          },
          %{
            "jsonrpc" => "2.0",
            "id" => 4,
            "method" => "tools/call",
            "params" => %{
              "name" => "workflow_validate",
              "arguments" => %{"script_path" => missing_path}
            }
          },
          %{"jsonrpc" => "2.0", "id" => 5, "method" => "shutdown", "params" => %{}}
        ]
        |> Enum.map_join("\n", &Jason.encode!/1)
        |> Kernel.<>("\n")

      File.write!(input_path, input)

      {stdout, status} =
        System.cmd(
          "sh",
          ["-c", "cat \"$1\" | \"$2\" --stdio", "proof-mcp", input_path, entrypoint],
          cd: repo_root,
          env: env,
          stderr_to_stdout: false
        )

      assert!(status == 0, "MCP adapter exited with #{status}\n#{stdout}")

      responses =
        stdout
        |> String.split("\n", trim: true)
        |> Enum.map(&Jason.decode!/1)
        |> Map.new(fn %{"id" => id} = message -> {id, message} end)

      assert_initialize!(responses[1])
      assert_tools_list!(responses[2])
      assert_successful_validation!(responses[3], workflow_path)
      assert_missing_script_validation!(responses[4], missing_path)
      assert!(responses[5]["result"] == %{}, "shutdown should return an empty result")

      assert_scheduler_stopped!(scheduler_url)
      IO.puts("MCP validation proof passed on #{scheduler_url}")
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

  defp workflow_source do
    """
    defmodule MCPValidateProofWorkflow do
      use Workflow

      workflow "mcp-validate-proof" do
        phase "proof"
        log "mcp validation proof"
        return :ok
      end
    end
    """
  end

  defp assert_initialize!(%{"result" => %{"serverInfo" => %{"name" => "codex-loops"}}}), do: :ok

  defp assert_initialize!(message),
    do: raise("initialize response was not valid: #{inspect(message)}")

  defp assert_tools_list!(%{"result" => %{"tools" => [%{"name" => "workflow_validate"}]}}),
    do: :ok

  defp assert_tools_list!(message),
    do: raise("tools/list response was not valid: #{inspect(message)}")

  defp assert_successful_validation!(%{"result" => result}, workflow_path) do
    assert!(result["isError"] == false, "valid workflow should not be an MCP error")
    payload = result["structuredContent"]

    assert!(
      payload["api_version"] == "scheduler.v1",
      "valid workflow should return scheduler envelope"
    )

    assert!(payload["data"]["valid"] == true, "valid workflow should be valid")

    assert!(
      payload["data"]["workflow_name"] == "mcp-validate-proof",
      "workflow name should be preserved"
    )

    assert!(payload["data"]["script"]["path"] == workflow_path, "script path should be preserved")
  end

  defp assert_successful_validation!(message, _workflow_path),
    do: raise("workflow_validate success response was not valid: #{inspect(message)}")

  defp assert_missing_script_validation!(%{"result" => result}, missing_path) do
    assert!(result["isError"] == true, "missing workflow should be an MCP error")
    payload = result["structuredContent"]

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

  defp assert_missing_script_validation!(message, _missing_path),
    do: raise("workflow_validate error response was not valid: #{inspect(message)}")

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
      [timeout: @timeout_ms, connect_timeout: @timeout_ms],
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
