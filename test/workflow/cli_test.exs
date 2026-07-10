defmodule Workflow.CLITest do
  use ExUnit.Case, async: true

  alias Workflow.CLI
  alias Workflow.PackageVersion

  @version PackageVersion.version()
  @marketplace_source "pproenca/codex-loops"

  describe "run" do
    @tag :tmp_dir
    test "validates and starts a live workflow with generated defaults, then opens its UI", %{tmp_dir: tmp_dir} do
      script = Path.join(tmp_dir, "answer.exs")
      File.write!(script, "workflow fixture")

      responses = [
        %{
          "api_version" => "scheduler.v1",
          "data" => %{"status" => "ok", "version" => @version}
        },
        %{
          "api_version" => "scheduler.v1",
          "data" => %{
            "valid" => true,
            "workflow_name" => "answer",
            "script" => %{"path" => script}
          }
        },
        %{
          "api_version" => "scheduler.v1",
          "data" => %{"run_id" => "answer-test-run", "state" => "accepted"}
        }
      ]

      server_url = serve_http(responses)
      parent = self()

      assert {:ok, result} =
               CLI.run(["run", script, "--open", "--server", server_url],
                 run_id: fn _script -> "answer-test-run" end,
                 open_url: fn url ->
                   send(parent, {:opened, url})
                   :ok
                 end
               )

      assert result.command == :run
      assert result.provider == "codex"
      assert result.run_id == "answer-test-run"
      assert result.ui_url == server_url <> "/runs/answer-test-run"
      assert result.opened == true
      assert_received {:opened, url}
      assert url == result.ui_url

      assert_receive {:http_request, health_request}
      assert health_request =~ "GET /api/health "

      assert_receive {:http_request, validate_request}
      assert validate_request =~ "POST /api/workflows/validate "
      assert validate_request =~ Jason.encode!(%{"script_path" => script})

      assert_receive {:http_request, start_request}
      assert start_request =~ "POST /api/runs "
      assert start_request =~ ~s("provider":"codex")
      assert start_request =~ ~s("run_id":"answer-test-run")
      assert start_request =~ Jason.encode!(script)
    end

    @tag :tmp_dir
    test "starts a missing local scheduler before launching the workflow", %{tmp_dir: tmp_dir} do
      script = Path.join(tmp_dir, "answer.exs")
      scheduler_bin = Path.join(tmp_dir, "agent_loops")
      File.write!(script, "workflow fixture")
      File.write!(scheduler_bin, "#!/bin/sh\nexit 0\n")
      File.chmod!(scheduler_bin, 0o755)

      unhealthy = %{
        "api_version" => "scheduler.v1",
        "data" => %{"status" => "ok", "version" => "not-ready"}
      }

      healthy = %{
        "api_version" => "scheduler.v1",
        "data" => %{"status" => "ok", "version" => @version}
      }

      validation = %{
        "api_version" => "scheduler.v1",
        "data" => %{"valid" => true, "workflow_name" => "answer", "script" => %{"path" => script}}
      }

      started = %{
        "api_version" => "scheduler.v1",
        "data" => %{"run_id" => "answer-autostart", "state" => "accepted"}
      }

      server_url = serve_http([unhealthy, unhealthy, healthy, validation, started])
      parent = self()

      command = fn executable, args, opts ->
        send(parent, {:scheduler_command, executable, args, opts})
        {"", 0}
      end

      assert {:ok, result} =
               CLI.run(["run", script, "--server", server_url],
                 scheduler_bin: scheduler_bin,
                 command: command,
                 announce: fn _server -> :ok end,
                 run_id: fn _script -> "answer-autostart" end
               )

      assert result.run_id == "answer-autostart"
      assert_received {:scheduler_command, ^scheduler_bin, ["daemon"], command_opts}

      assert {"CODEX_LOOPS_PORT", server_url |> URI.parse() |> Map.fetch!(:port) |> Integer.to_string()} in command_opts[
               :env
             ]
    end
  end

  describe "serve" do
    @tag :tmp_dir
    test "starts the packaged scheduler as a managed local daemon with defaults", %{tmp_dir: tmp_dir} do
      parent = self()
      scheduler_bin = Path.join(tmp_dir, "agent_loops")
      File.write!(scheduler_bin, "#!/bin/sh\nexit 0\n")
      File.chmod!(scheduler_bin, 0o755)
      {:ok, health} = Agent.start_link(fn -> [:down, :ok] end)

      command = fn executable, args, opts ->
        send(parent, {:scheduler_command, executable, args, opts})
        {"", 0}
      end

      assert {:ok, result} =
               CLI.run(["serve"],
                 scheduler_bin: scheduler_bin,
                 command: command,
                 health: fn -> Agent.get_and_update(health, fn [next | rest] -> {next, rest} end) end,
                 announce: fn _server -> :ok end
               )

      assert result.command == :serve
      assert result.state == :running
      assert result.server_url == "http://127.0.0.1:47125"

      assert_received {:scheduler_command, ^scheduler_bin, ["daemon"], command_opts}
      assert {"CODEX_LOOPS_SERVER", "1"} in command_opts[:env]
      assert {"CODEX_LOOPS_HOST", "127.0.0.1"} in command_opts[:env]
      assert {"CODEX_LOOPS_PORT", "47125"} in command_opts[:env]
      assert {"PORT", "47125"} in command_opts[:env]
      assert {"RELEASE_DISTRIBUTION", "sname"} in command_opts[:env]
      assert {"RELEASE_NODE", "codex_loops"} in command_opts[:env]
    end

    @tag :tmp_dir
    test "rejects runtime overrides that cannot affect an existing scheduler", %{tmp_dir: tmp_dir} do
      scheduler_bin = Path.join(tmp_dir, "agent_loops")
      File.write!(scheduler_bin, "#!/bin/sh\nexit 0\n")
      File.chmod!(scheduler_bin, 0o755)

      assert {:error, 2, error} =
               CLI.run(["serve", "--journal", "/tmp/other.sqlite"],
                 scheduler_bin: scheduler_bin,
                 health: fn -> :ok end,
                 announce: fn _server -> flunk("serve must fail before announcing") end
               )

      assert error.code == "scheduler_already_running"
      assert error.message =~ "cannot be applied"
      assert error.message =~ "codex-loops stop"
    end

    test "stop rejects serve-only options" do
      assert {:error, 2, error} = CLI.run(["stop", "--model", "gpt-example"])
      assert error.code == "usage"
      assert error.message =~ "Unknown stop option"
      assert error.message =~ "Usage: codex-loops stop"
    end

    @tag :tmp_dir
    test "stop shuts down the managed local scheduler", %{tmp_dir: tmp_dir} do
      parent = self()
      scheduler_bin = Path.join(tmp_dir, "agent_loops")
      File.write!(scheduler_bin, "#!/bin/sh\nexit 0\n")
      File.chmod!(scheduler_bin, 0o755)
      {:ok, health} = Agent.start_link(fn -> [:ok, :down] end)

      command = fn executable, args, opts ->
        send(parent, {:scheduler_command, executable, args, opts})
        {"", 0}
      end

      assert {:ok, result} =
               CLI.run(["stop"],
                 scheduler_bin: scheduler_bin,
                 command: command,
                 health: fn -> Agent.get_and_update(health, fn [next | rest] -> {next, rest} end) end
               )

      assert result.command == :stop
      assert result.state == :stopped
      assert_received {:scheduler_command, ^scheduler_bin, ["stop"], command_opts}
      assert {"RELEASE_DISTRIBUTION", "sname"} in command_opts[:env]
      assert {"RELEASE_NODE", "codex_loops"} in command_opts[:env]
    end
  end

  test "install --check succeeds when runtime, marketplace, and plugin match" do
    runtime_root = runtime_fixture()

    assert {:ok, result} =
             CLI.run(["install", "--check"],
               runtime_root: runtime_root,
               codex_bin: "/fake/codex",
               command: command_fixture(marketplaces: [marketplace()], plugins: [plugin()])
             )

    assert result.changed == false
    assert result.runtime.version == @version
    assert result.plugin.enabled == true
    assert result.plan == []
  end

  test "install --dry-run reports the deterministic plan without mutations" do
    runtime_root = runtime_fixture()
    parent = self()

    command =
      command_fixture(marketplaces: [], plugins: [], notify: fn args -> send(parent, {:command, args}) end)

    assert {:ok, result} =
             CLI.run(["install", "--dry-run"],
               runtime_root: runtime_root,
               codex_bin: "/fake/codex",
               command: command
             )

    assert result.changed == false
    assert result.plan == ["add_marketplace", "install_plugin"]
    refute_received {:command, ["plugin", "marketplace", "add", @marketplace_source | _rest]}
    refute_received {:command, ["plugin", "add", "codex-loops@codex-loops" | _rest]}
  end

  test "install applies missing Codex Loops state and verifies the result" do
    runtime_root = runtime_fixture()
    {:ok, state} = Agent.start_link(fn -> %{installed?: false} end)

    command = fn args ->
      if args == ["--version"] do
        {"codex-cli 0.142.5\n", 0}
      else
        if List.last(args) == "--help" do
          {"Usage: codex plugin --json", 0}
        else
          case args do
            ["plugin", "marketplace", "add" | _rest] ->
              Agent.update(state, &Map.put(&1, :installed?, true))
              {~s({"ok":true}), 0}

            ["plugin", "add" | _rest] ->
              {~s({"ok":true}), 0}

            ["plugin", "marketplace", "list", "--json"] ->
              if Agent.get(state, & &1.installed?) do
                {Jason.encode!(%{"marketplaces" => [marketplace()]}), 0}
              else
                {~s({"marketplaces":[]}), 0}
              end

            ["plugin", "list", "--json"] ->
              if Agent.get(state, & &1.installed?) do
                {Jason.encode!(%{"installed" => [plugin()], "available" => []}), 0}
              else
                {~s({"installed":[],"available":[]}), 0}
              end

            _other ->
              {"unexpected", 1}
          end
        end
      end
    end

    assert {:ok, result} =
             CLI.run(["install"],
               runtime_root: runtime_root,
               codex_bin: "/fake/codex",
               command: command
             )

    assert result.changed == true
    assert result.plan == ["add_marketplace", "install_plugin"]
  end

  test "install fails closed on a marketplace owned by another source" do
    runtime_root = runtime_fixture()

    conflicting =
      marketplace(%{
        "marketplaceSource" => %{"sourceType" => "git", "source" => "someone/else"}
      })

    assert {:error, 4, error} =
             CLI.run(["install", "--check"],
               runtime_root: runtime_root,
               codex_bin: "/fake/codex",
               command: command_fixture(marketplaces: [conflicting], plugins: [])
             )

    assert error.code == "marketplace_conflict"
    assert error.message =~ "someone/else"
  end

  test "install reports a stable prerequisite error when Codex is missing" do
    runtime_root = runtime_fixture()

    assert {:error, 3, error} =
             CLI.run(["install", "--check"],
               runtime_root: runtime_root,
               codex_bin: nil
             )

    assert error.code == "codex_missing"
    assert error.message =~ "brew install --cask codex"
  end

  test "install preserves changed state and failing step when verification fails" do
    runtime_root = runtime_fixture()
    {:ok, state} = Agent.start_link(fn -> :before_write end)

    command = fn args ->
      if List.last(args) == "--help" do
        {"Usage: codex plugin --json", 0}
      else
        case args do
          ["--version"] ->
            {"codex-cli 0.142.5\n", 0}

          ["plugin", "marketplace", "list", "--json"] ->
            case Agent.get(state, & &1) do
              :before_write -> {~s({"marketplaces":[]}), 0}
              :after_write -> {"verification unavailable", 9}
            end

          ["plugin", "list", "--json"] ->
            {~s({"installed":[],"available":[]}), 0}

          ["plugin", "marketplace", "add" | _rest] ->
            Agent.update(state, fn _current -> :after_write end)
            {~s({"ok":true}), 0}

          ["plugin", "add" | _rest] ->
            {~s({"ok":true}), 0}

          _other ->
            {"unexpected", 1}
        end
      end
    end

    assert {:error, 5, error} =
             CLI.run(["install"],
               runtime_root: runtime_root,
               codex_bin: "/fake/codex",
               command: command
             )

    assert error.changed == true
    assert error.step == "marketplace_list"
  end

  defp command_fixture(opts) do
    marketplaces = Keyword.fetch!(opts, :marketplaces)
    plugins = Keyword.fetch!(opts, :plugins)
    notify = Keyword.get(opts, :notify, fn _args -> :ok end)

    fn args ->
      notify.(args)

      case args do
        ["--version"] ->
          {"codex-cli 0.142.5\n", 0}

        ["plugin", "marketplace", "list", "--json"] ->
          {Jason.encode!(%{"marketplaces" => marketplaces}), 0}

        ["plugin", "list", "--json"] ->
          {Jason.encode!(%{"installed" => plugins, "available" => []}), 0}

        _help ->
          {"Usage: codex plugin --json", 0}
      end
    end
  end

  defp marketplace(overrides \\ %{}) do
    Map.merge(
      %{
        "name" => "codex-loops",
        "marketplaceSource" => %{
          "sourceType" => "git",
          "source" => "pproenca/codex-loops",
          "ref" => "v#{@version}"
        }
      },
      overrides
    )
  end

  defp plugin do
    %{
      "pluginId" => "codex-loops@codex-loops",
      "name" => "codex-loops",
      "marketplaceName" => "codex-loops",
      "version" => @version,
      "installed" => true,
      "enabled" => true,
      "source" => %{"source" => "local", "path" => "plugins/codex-loops"}
    }
  end

  defp runtime_fixture do
    root =
      Path.join(System.tmp_dir!(), "codex-loops-cli-#{System.unique_integer([:positive])}")

    scheduler = Path.join(root, "scheduler/bin/agent_loops")
    mcp = Path.join(root, "mcp/codex-loops-mcp")
    File.mkdir_p!(Path.dirname(scheduler))
    File.mkdir_p!(Path.dirname(mcp))
    File.write!(scheduler, "#!/bin/sh\nexit 0\n")
    File.write!(mcp, "#!/bin/sh\necho 'codex-loops-mcp #{@version}'\n")
    File.chmod!(scheduler, 0o755)
    File.chmod!(mcp, 0o755)
    on_exit(fn -> File.rm_rf(root) end)
    root
  end

  defp serve_http(responses) do
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
        {:ok, socket} = :gen_tcp.accept(listen_socket, 5_000)
        request = receive_http_request(socket, "")
        send(parent, {:http_request, request})

        body = Jason.encode!(response)

        :ok =
          :gen_tcp.send(socket, [
            "HTTP/1.1 200 OK\r\n",
            "content-type: application/json\r\n",
            "content-length: ",
            Integer.to_string(byte_size(body)),
            "\r\nconnection: close\r\n\r\n",
            body
          ])

        :gen_tcp.close(socket)
      end)

      :gen_tcp.close(listen_socket)
    end)

    "http://127.0.0.1:#{port}"
  end

  defp receive_http_request(socket, acc) do
    if complete_http_request?(acc) do
      acc
    else
      {:ok, data} = :gen_tcp.recv(socket, 0, 5_000)
      receive_http_request(socket, acc <> data)
    end
  end

  defp complete_http_request?(request) do
    case String.split(request, "\r\n\r\n", parts: 2) do
      [headers, body] -> byte_size(body) >= content_length(headers)
      [_headers] -> false
    end
  end

  defp content_length(headers) do
    case Regex.run(~r/content-length:\s*(\d+)/i, headers, capture: :all_but_first) do
      [raw] -> String.to_integer(raw)
      nil -> 0
    end
  end
end
