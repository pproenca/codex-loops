defmodule Workflow.InstallTest do
  use ExUnit.Case, async: false

  alias Workflow.Install
  alias Workflow.Install.CodexBinding
  alias Workflow.Install.Command
  alias Workflow.Install.Error
  alias Workflow.Install.Lock
  alias Workflow.Install.MCP
  alias Workflow.Install.Service
  alias Workflow.Install.Skill
  alias Workflow.PackageVersion

  test "command deadlines are total even while a child trickles output" do
    started = System.monotonic_time(:millisecond)

    assert {:error, :timeout} =
             Command.run(
               "/bin/sh",
               ["-c", "i=0; while [ $i -lt 20 ]; do printf x; i=$((i + 1)); sleep 0.02; done"],
               timeout: 60,
               max_output_bytes: 1_000_000
             )

    assert System.monotonic_time(:millisecond) - started < 500
  end

  test "Codex binding persists and verifies only the exact executable and version" do
    fixture = fixture()

    assert {:ok, binding} = CodexBinding.probe(fixture.codex, fixture.opts)
    assert binding.version == "codex-cli 9.9.9"
    assert :ok = CodexBinding.persist(binding, fixture.opts)
    assert {:ok, ^binding} = CodexBinding.read(fixture.opts)
    assert {:ok, {fixture.codex, []}} == CodexBinding.command(fixture.opts)

    persisted = fixture.binding_path |> File.read!() |> Jason.decode!()
    assert persisted |> Map.keys() |> Enum.sort() == ["path", "version"]

    Agent.update(fixture.agent, &%{&1 | version: "codex-cli 10.0.0"})
    assert {:error, %Error{code: "codex_binding_changed"}} = CodexBinding.verify(binding, fixture.opts)

    File.write!(fixture.binding_path, Jason.encode!(%{"path" => fixture.codex, "version" => "codex-cli "}))
    assert {:error, %Error{code: "codex_binding_invalid"}} = CodexBinding.read(fixture.opts)
  end

  test "service definitions run the release in foreground and rollback cleanly" do
    fixture = fixture()
    binding = codex_binding(fixture)
    assert {:ok, config} = Service.config(binding, fixture.opts)

    assert config.content =~ "ExecStart=\"#{fixture.release}\" foreground"
    assert config.content =~ "CODEX_LOOPS_BINDING_PATH=#{fixture.binding_path}"
    assert config.content =~ "CODEX_LOOPS_CODEX_BIN=#{fixture.codex}"
    refute config.content =~ " agent_loops start"

    assert {:ok, change} = Service.install(config, fixture.opts)
    assert File.read!(fixture.service_path) == config.content
    assert {:ok, :current} = Service.inspect_state(config, fixture.opts)
    assert :ok = change.rollback.()
    refute File.exists?(fixture.service_path)
  end

  test "service URLs bracket IPv6 loopback hosts" do
    fixture = fixture()
    opts = Keyword.put(fixture.opts, :host, "::1")

    assert {:ok, config} = Service.config(codex_binding(fixture), opts)
    assert Service.base_url(config) == "http://[::1]:47125"
  end

  test "service installation refuses a foreign definition without invoking the manager" do
    fixture = fixture()
    assert {:ok, config} = Service.config(codex_binding(fixture), fixture.opts)
    File.mkdir_p!(Path.dirname(fixture.service_path))
    foreign = "foreign service\n# Managed by Codex Loops\n"
    File.write!(fixture.service_path, foreign)
    manager = fixture.manager

    assert {:error, %Error{code: "service_definition_conflict"}} = Service.install(config, fixture.opts)
    assert File.read!(fixture.service_path) == foreign
    refute_received {:command, ^manager, _args}
  end

  test "a failed service upgrade restores and verifies the previously healthy version" do
    fixture = fixture()
    assert {:ok, config} = Service.config(codex_binding(fixture), fixture.opts)
    old_definition = "# Managed by Codex Loops\nExecStart=/old/codex-loops-server foreground\n"
    old_version = "0.2.6"
    File.mkdir_p!(Path.dirname(fixture.service_path))
    File.write!(fixture.service_path, old_definition)

    health_check = fn _url ->
      case File.read(fixture.service_path) do
        {:ok, ^old_definition} -> {:other_version, old_version}
        {:ok, content} when content == config.content -> :unreachable
        {:error, :enoent} -> :unreachable
      end
    end

    opts =
      fixture.opts
      |> Keyword.put(:health_check, health_check)
      |> Keyword.put(:health_timeout, 5)
      |> Keyword.put(:health_interval, 1)

    assert {:error, %Error{code: "service_health_failed"}} = Service.install(config, opts)
    assert File.read!(fixture.service_path) == old_definition
    assert health_check.(Service.base_url(config)) == {:other_version, old_version}
  end

  test "service rollback preserves an external definition and does not deactivate it" do
    fixture = fixture()
    assert {:ok, config} = Service.config(codex_binding(fixture), fixture.opts)
    assert {:ok, change} = Service.install(config, fixture.opts)
    drain_commands()

    external = "# Managed by Codex Loops\nExecStart=/external/scheduler foreground\n"
    File.write!(fixture.service_path, external)

    assert {:error, %Error{code: "service_definition_changed"}} = change.rollback.()
    assert File.read!(fixture.service_path) == external
    refute Enum.any?(drain_commands(), &manager_mutation?(&1, fixture.manager))
  end

  test "service state requires the exact systemd manager state and rollback restores all prior flags" do
    for {enabled?, active?} <- [{false, false}, {false, true}, {true, false}, {true, true}] do
      fixture = fixture(manager_enabled?: enabled?, manager_active?: active?)
      assert {:ok, config} = Service.config(codex_binding(fixture), fixture.opts)
      File.mkdir_p!(Path.dirname(fixture.service_path))
      File.write!(fixture.service_path, config.content)

      expected_state = if enabled? and active?, do: :current, else: :drifted
      assert {:ok, ^expected_state} = Service.inspect_state(config, fixture.opts)
      assert {:ok, change} = Service.install(config, fixture.opts)
      assert Agent.get(fixture.agent, &{&1.manager_enabled?, &1.manager_active?}) == {true, true}
      assert :ok = change.rollback.()
      assert Agent.get(fixture.agent, &{&1.manager_enabled?, &1.manager_active?}) == {enabled?, active?}
    end
  end

  test "launchd loaded state participates in inspection and rollback" do
    fixture = fixture(manager_loaded?: false)
    service_path = Path.join(fixture.root, "home/Library/LaunchAgents/codex-loops.plist")

    opts =
      fixture.opts
      |> Keyword.put(:platform, :darwin)
      |> Keyword.put(:manager_command, "/fake/launchctl")
      |> Keyword.put(:service_path, service_path)
      |> Keyword.put(:uid, 501)
      |> Keyword.put(:health_check, fn _url -> if File.regular?(service_path), do: :compatible, else: :unreachable end)

    assert {:ok, config} = Service.config(codex_binding(fixture), opts)
    File.mkdir_p!(Path.dirname(config.definition_path))
    File.write!(config.definition_path, config.content)

    assert {:ok, :drifted} = Service.inspect_state(config, opts)
    assert {:ok, change} = Service.install(config, opts)
    assert Agent.get(fixture.agent, & &1.manager_loaded?)
    assert :ok = change.rollback.()
    refute Agent.get(fixture.agent, & &1.manager_loaded?)
  end

  test "service definitions reject symlinks without touching their targets" do
    fixture = fixture()
    assert {:ok, config} = Service.config(codex_binding(fixture), fixture.opts)
    target = Path.join(fixture.root, "external.service")
    external = "external service\n"
    File.write!(target, external)
    File.mkdir_p!(Path.dirname(fixture.service_path))
    File.ln_s!(target, fixture.service_path)

    assert {:error, %Error{code: "service_definition_symlink"}} =
             Service.inspect_state(config, fixture.opts)

    assert {:error, %Error{code: "service_definition_symlink"}} = Service.install(config, fixture.opts)
    assert File.read!(target) == external
    refute Enum.any?(drain_commands(), &manager_mutation?(&1, fixture.manager))
  end

  test "service config rejects relative paths and control-character injection" do
    fixture = fixture()
    binding = codex_binding(fixture)

    assert {:error, %Error{code: "service_path_invalid"}} =
             Service.config(binding, Keyword.put(fixture.opts, :working_directory, "relative"))

    injected = Path.join(fixture.root, "work\nEnvironment=INJECTED=1")

    assert {:error, %Error{code: "service_value_invalid"}} =
             Service.config(binding, Keyword.put(fixture.opts, :working_directory, injected))

    assert {:error, %Error{code: "service_path_invalid"}} =
             Service.config(
               binding,
               fixture.opts |> Keyword.delete(:service_path) |> Keyword.put(:xdg_config_home, "relative")
             )
  end

  test "systemd rendering preserves literal percent specifiers and ExecStart dollars" do
    fixture = fixture()
    release = executable!(Path.join(fixture.root, "bundle/$release%h/codex-loops-server"))
    working_directory = Path.join(fixture.root, "work%h")

    opts =
      fixture.opts
      |> Keyword.put(:release_command, release)
      |> Keyword.put(:working_directory, working_directory)

    assert {:ok, config} = Service.config(codex_binding(fixture), opts)
    assert config.content =~ "WorkingDirectory=\"#{String.replace(working_directory, "%", "%%")}\""

    escaped_release = release |> String.replace("$", "$$") |> String.replace("%", "%%")
    assert config.content =~ "ExecStart=\"#{escaped_release}\" foreground"
  end

  test "service persists a safe PATH containing the lexical Codex directory and an absolute CODEX_HOME" do
    fixture = fixture()
    codex_home = Path.join(fixture.root, "custom-codex-home")

    opts =
      fixture.opts
      |> Keyword.put(:path_env, "/usr/bin:/bin")
      |> Keyword.put(:codex_home, codex_home)

    assert {:ok, config} = Service.config(codex_binding(fixture), opts)
    expected_path = Path.dirname(fixture.codex) <> ":/usr/bin:/bin"
    assert config.content =~ "Environment=\"PATH=#{expected_path}\""
    assert config.content =~ "Environment=\"CODEX_HOME=#{codex_home}\""

    for invalid <- ["", "relative:/bin", "/usr/bin::/bin", "/usr/bin:\n/bin"] do
      assert {:error, %Error{code: "service_path_env_invalid"}} =
               Service.config(codex_binding(fixture), Keyword.put(fixture.opts, :path_env, invalid))
    end

    assert {:error, %Error{code: "codex_home_invalid"}} =
             Service.config(codex_binding(fixture), Keyword.put(fixture.opts, :codex_home, "relative"))
  end

  test "an atomic definition write failure does not deactivate the old service" do
    fixture = fixture()
    blocked_parent = Path.join(fixture.root, "blocked")
    service_path = Path.join(blocked_parent, "codex-loops.service")
    File.mkdir_p!(blocked_parent)
    File.chmod!(blocked_parent, 0o500)

    try do
      opts = Keyword.put(fixture.opts, :service_path, service_path)
      manager = fixture.manager
      assert {:ok, config} = Service.config(codex_binding(fixture), opts)
      assert {:error, %Error{code: "service_write_failed"}} = Service.install(config, opts)
      refute Enum.any?(drain_commands(), &manager_mutation?(&1, manager))
    after
      File.chmod!(blocked_parent, 0o700)
    end
  end

  test "the MCP endpoint gate verifies request media and exact initialize result" do
    fixture = fixture()
    sink = self()

    client = fn method, request, http_options, response_options ->
      send(sink, {:http_request, method, request, http_options, response_options})

      body =
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => "codex-loops-install-probe",
          "result" => %{
            "protocolVersion" => "2025-03-26",
            "capabilities" => %{"tools" => %{"listChanged" => false}},
            "serverInfo" => %{"name" => "codex-loops", "version" => PackageVersion.version()}
          }
        })

      {:ok, {{~c"HTTP/1.1", 200, ~c"OK"}, [{~c"content-type", ~c"application/json; charset=utf-8"}], body}}
    end

    assert :ok = MCP.probe_endpoint("http://127.0.0.1:47125", mcp_http_client: client)

    assert_receive {:http_request, :post, {url, headers, content_type, request_body}, http_options,
                    [body_format: :binary]}

    assert to_string(url) == "http://127.0.0.1:47125/mcp"
    assert content_type == ~c"application/json"
    assert {~c"accept", ~c"application/json, text/event-stream"} in headers
    assert http_options[:timeout] == 1_000
    assert Jason.decode!(request_body)["params"]["protocolVersion"] == "2025-03-26"

    wrong_version_client = fn _method, _request, _http_options, _response_options ->
      body =
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => "codex-loops-install-probe",
          "result" => %{
            "protocolVersion" => "2025-03-26",
            "capabilities" => %{"tools" => %{"listChanged" => false}},
            "serverInfo" => %{"name" => "codex-loops", "version" => "old"}
          }
        })

      {:ok, {{~c"HTTP/1.1", 200, ~c"OK"}, [{~c"content-type", ~c"application/json"}], body}}
    end

    assert {:error, %Error{code: "mcp_endpoint_invalid"}} =
             MCP.probe_endpoint("http://127.0.0.1:47125", mcp_http_client: wrong_version_client)

    assert fixture.root
  end

  test "MCP replacement is exact, re-read after add, and restorable" do
    fixture = fixture(registration: stdio_server("/old/mcp", ["serve"]))
    binding = codex_binding(fixture)

    assert {:ok, {:replace, _previous} = state} = MCP.inspect_state(binding, fixture.opts)
    assert {:ok, change} = MCP.install(binding, state, fixture.opts)
    assert Agent.get(fixture.agent, & &1.registration) == http_server(MCP.url())

    assert :ok = change.rollback.()
    assert Agent.get(fixture.agent, & &1.registration) == stdio_server("/old/mcp", ["serve"])
  end

  test "MCP add exit zero is rejected when list does not contain the exact URL" do
    fixture = fixture(persist_current?: false)
    binding = codex_binding(fixture)
    assert {:ok, :missing} = MCP.inspect_state(binding, fixture.opts)

    assert {:error, %Error{code: "mcp_registration_verify_failed"}} =
             MCP.install(binding, :missing, fixture.opts)

    assert Agent.get(fixture.agent, & &1.registration) == nil
  end

  test "MCP restoration rejects unknown server and transport fields before mutation" do
    unknown_server = Map.put(stdio_server("/old/mcp", []), "oauth_state", %{"token" => "opaque"})
    fixture = fixture(registration: unknown_server)
    codex = fixture.codex

    assert {:error, %Error{code: "mcp_registration_not_restorable"}} =
             MCP.inspect_state(codex_binding(fixture), fixture.opts)

    refute_received {:command, ^codex, ["mcp", "remove", "codex-loops"]}

    unknown_transport = put_in(stdio_server("/old/mcp", [])["transport"]["oauth"], %{"enabled" => true})
    Agent.update(fixture.agent, &%{&1 | registration: unknown_transport})

    assert {:error, %Error{code: "mcp_registration_not_restorable"}} =
             MCP.inspect_state(codex_binding(fixture), fixture.opts)
  end

  test "MCP replacement refuses tool filters that codex mcp add cannot restore" do
    for {field, value} <- [{"enabled_tools", ["workflow_start"]}, {"disabled_tools", []}] do
      registration = Map.put(stdio_server("/old/mcp", []), field, value)
      fixture = fixture(registration: registration)
      codex = fixture.codex

      assert {:error, %Error{code: "mcp_registration_not_restorable"} = error} =
               MCP.inspect_state(codex_binding(fixture), fixture.opts)

      assert error.details["reason"] == "codex_mcp_add_cannot_restore_tool_filters"
      assert Agent.get(fixture.agent, & &1.registration) == registration
      refute_received {:command, ^codex, ["mcp", "remove", "codex-loops"]}
    end
  end

  test "MCP rollback is compare-and-swap and preserves an external replacement" do
    fixture = fixture(registration: stdio_server("/old/mcp", ["serve"]))
    binding = codex_binding(fixture)
    assert {:ok, {:replace, _previous} = state} = MCP.inspect_state(binding, fixture.opts)
    assert {:ok, change} = MCP.install(binding, state, fixture.opts)
    drain_commands()

    external = stdio_server("/external/mcp", ["new"])
    Agent.update(fixture.agent, &%{&1 | registration: external})

    assert {:error, %Error{code: "mcp_registration_changed"}} = change.rollback.()
    assert Agent.get(fixture.agent, & &1.registration) == external
    codex = fixture.codex
    refute_received {:command, ^codex, ["mcp", "remove", "codex-loops"]}
  end

  test "MCP successful-change rollback treats externally removed prior state as a conflict" do
    fixture = fixture(registration: stdio_server("/old/mcp", ["serve"]))
    binding = codex_binding(fixture)
    assert {:ok, {:replace, _previous} = state} = MCP.inspect_state(binding, fixture.opts)
    assert {:ok, change} = MCP.install(binding, state, fixture.opts)
    Agent.update(fixture.agent, &%{&1 | registration: nil})
    drain_commands()

    assert {:error, %Error{code: "mcp_registration_changed"}} = change.rollback.()
    assert Agent.get(fixture.agent, & &1.registration) == nil
    codex = fixture.codex
    refute_received {:command, ^codex, ["mcp", "add", "codex-loops", "--", _command | _args]}
  end

  test "skill installation handles glob characters and refuses an unowned destination" do
    fixture = fixture()
    assert {:ok, config} = Skill.config(fixture.opts)
    assert {:ok, change} = Skill.install(config)
    assert {:ok, :current} = Skill.inspect_state(config)
    assert File.read!(Path.join(fixture.skill_path, "nested/.hidden")) == "hidden\n"
    assert :ok = change.rollback.()

    File.mkdir_p!(fixture.skill_path)
    File.write!(Path.join(fixture.skill_path, "mine.txt"), "preserve\n")
    assert {:error, %Error{code: "skill_destination_conflict"}} = Skill.install(config)
    assert File.read!(Path.join(fixture.skill_path, "mine.txt")) == "preserve\n"
  end

  test "skill successful-change rollback does not restore over an externally removed prior destination" do
    fixture = fixture()
    assert {:ok, config} = Skill.config(fixture.opts)
    assert {:ok, first} = Skill.install(config)
    assert :ok = first.commit.()
    File.write!(Path.join(fixture.skill_source, "SKILL.md"), "# Updated\n")
    assert {:ok, config} = Skill.config(fixture.opts)
    assert {:ok, change} = Skill.install(config)
    File.rm_rf!(fixture.skill_path)

    assert {:error, :installed_skill_removed} = change.rollback.()
    refute File.exists?(fixture.skill_path)

    backups =
      fixture.skill_path
      |> Path.dirname()
      |> File.ls!()
      |> Enum.filter(&String.starts_with?(&1, "codex-loops.backup."))

    assert length(backups) == 1
  end

  test "one install reconciles every surface and repeat install/check are idempotent" do
    fixture = fixture()

    assert {:ok, installed} = Install.run(:install, fixture.opts)
    assert installed["changed"]
    assert installed["plan"] == ["bind_codex", "install_service", "install_skill", "add_mcp"]
    assert installed["service"]["state"] == "current"
    assert installed["skill"]["state"] == "current"
    assert installed["mcp"]["state"] == "current"
    assert File.regular?(fixture.binding_path)
    assert File.regular?(fixture.service_path)
    assert File.regular?(Path.join(fixture.skill_path, "SKILL.md"))
    assert Agent.get(fixture.agent, & &1.registration) == http_server(MCP.url())

    assert {:ok, repeated} = Install.run(:install, fixture.opts)
    refute repeated["changed"]
    assert repeated["plan"] == []
    assert {:ok, %{"plan" => []}} = Install.run(:check, fixture.opts)
  end

  test "a broken current MCP endpoint fails check rather than trusting health" do
    fixture = fixture()
    assert {:ok, _installed} = Install.run(:install, fixture.opts)

    broken_probe = fn _url ->
      {:error, Error.new(6, "mcp_endpoint_invalid", "broken endpoint", step: "mcp_endpoint_probe")}
    end

    assert {:error, %Error{code: "mcp_endpoint_invalid"}} =
             Install.run(:check, Keyword.put(fixture.opts, :mcp_endpoint_probe, broken_probe))
  end

  test "a late MCP failure rolls back binding, service, and skill" do
    fixture = fixture(fail_current_add?: true)

    assert {:error, %Error{code: "codex_command_failed", changed: true}} = Install.run(:install, fixture.opts)
    refute File.exists?(fixture.binding_path)
    refute File.exists?(fixture.service_path)
    refute File.exists?(fixture.skill_path)
    assert Agent.get(fixture.agent, & &1.registration) == nil
  end

  test "a binding change at the final gate rolls the complete transaction back" do
    fixture = fixture(version_after_add: "codex-cli 10.0.0")

    assert {:error, %Error{code: "codex_binding_changed", changed: true}} = Install.run(:install, fixture.opts)
    refute File.exists?(fixture.binding_path)
    refute File.exists?(fixture.service_path)
    refute File.exists?(fixture.skill_path)
    assert Agent.get(fixture.agent, & &1.registration) == nil
  end

  test "persisted binding drift fails the final gate and CAS rollback preserves the external file" do
    fixture = fixture()

    external =
      Jason.encode!(%{
        "path" => fixture.codex,
        "version" => "codex-cli 8.8.8"
      })

    Agent.update(fixture.agent, fn state ->
      %{state | after_current_add: fn -> File.write!(fixture.binding_path, external) end}
    end)

    assert {:error, %Error{code: "install_rollback_failed", changed: true} = error} =
             Install.run(:install, fixture.opts)

    assert get_in(error.details, ["install_error", "code"]) == "codex_binding_changed"
    assert File.read!(fixture.binding_path) == external
    refute File.exists?(fixture.service_path)
    refute File.exists?(fixture.skill_path)
    assert Agent.get(fixture.agent, & &1.registration) == nil
  end

  test "service definition drift at the final gate is detected and preserved by CAS rollback" do
    fixture = fixture()
    external = "# Managed by Codex Loops\nExecStart=/external/scheduler foreground\n"

    Agent.update(fixture.agent, fn state ->
      %{state | after_current_add: fn -> File.write!(fixture.service_path, external) end}
    end)

    assert {:error, %Error{code: "install_rollback_failed", changed: true} = error} =
             Install.run(:install, fixture.opts)

    assert get_in(error.details, ["install_error", "code"]) == "install_final_state_changed"
    assert get_in(error.details, ["install_error", "details", "surface"]) == "service"
    assert File.read!(fixture.service_path) == external
    refute File.exists?(fixture.binding_path)
    refute File.exists?(fixture.skill_path)
    assert Agent.get(fixture.agent, & &1.registration) == nil
  end

  test "service manager drift at the final gate is detected and preserved by CAS rollback" do
    fixture = fixture()

    Agent.update(fixture.agent, fn state ->
      %{
        state
        | after_current_add: fn ->
            Agent.update(fixture.agent, &%{&1 | manager_enabled?: true, manager_active?: false})
          end
      }
    end)

    assert {:error, %Error{code: "install_rollback_failed", changed: true} = error} =
             Install.run(:install, fixture.opts)

    assert get_in(error.details, ["install_error", "code"]) == "install_final_state_changed"
    assert get_in(error.details, ["install_error", "details", "surface"]) == "service"
    assert Agent.get(fixture.agent, &{&1.manager_enabled?, &1.manager_active?}) == {true, false}
    assert File.regular?(fixture.service_path)
    refute File.exists?(fixture.binding_path)
    refute File.exists?(fixture.skill_path)
    assert Agent.get(fixture.agent, & &1.registration) == nil
  end

  test "skill drift at the final gate is detected and preserved by CAS rollback" do
    fixture = fixture()
    external = "# External skill\n"

    Agent.update(fixture.agent, fn state ->
      %{
        state
        | after_current_add: fn -> File.write!(Path.join(fixture.skill_path, "SKILL.md"), external) end
      }
    end)

    assert {:error, %Error{code: "install_rollback_failed", changed: true} = error} =
             Install.run(:install, fixture.opts)

    assert get_in(error.details, ["install_error", "code"]) == "install_final_state_changed"
    assert get_in(error.details, ["install_error", "details", "surface"]) == "skill"
    assert File.read!(Path.join(fixture.skill_path, "SKILL.md")) == external
    refute File.exists?(fixture.binding_path)
    refute File.exists?(fixture.service_path)
    assert Agent.get(fixture.agent, & &1.registration) == nil
  end

  test "MCP drift at the final gate is detected and preserved by CAS rollback" do
    external = http_server("http://127.0.0.1:59999/mcp")
    fixture = fixture()

    Agent.update(fixture.agent, fn state ->
      %{
        state
        | after_mcp_list_count: 4,
          after_mcp_list: fn -> Agent.update(fixture.agent, &%{&1 | registration: external}) end
      }
    end)

    assert {:error, %Error{code: "install_rollback_failed", changed: true} = error} =
             Install.run(:install, fixture.opts)

    assert get_in(error.details, ["install_error", "code"]) == "install_final_state_changed"
    assert get_in(error.details, ["install_error", "details", "surface"]) == "mcp"
    assert Agent.get(fixture.agent, & &1.registration) == external
    refute File.exists?(fixture.binding_path)
    refute File.exists?(fixture.service_path)
    refute File.exists?(fixture.skill_path)
  end

  test "endpoint failure at the final gate rolls every changed surface back" do
    fixture = fixture(fail_mcp_probe_at: 2)

    assert {:error, %Error{code: "mcp_endpoint_invalid", changed: true}} =
             Install.run(:install, fixture.opts)

    refute File.exists?(fixture.binding_path)
    refute File.exists?(fixture.service_path)
    refute File.exists?(fixture.skill_path)
    assert Agent.get(fixture.agent, & &1.registration) == nil
    assert Agent.get(fixture.agent, & &1.mcp_probe_count) == 2
  end

  test "same-path Codex version drift also restarts the managed service" do
    fixture = fixture()
    assert {:ok, _installed} = Install.run(:install, fixture.opts)
    drain_commands()
    Agent.update(fixture.agent, &%{&1 | version: "codex-cli 10.0.0"})

    assert {:ok, updated} = Install.run(:install, fixture.opts)
    assert updated["plan"] == ["bind_codex", "install_service"]

    assert CodexBinding.read(fixture.opts) ==
             {:ok, %CodexBinding{path: fixture.codex, version: "codex-cli 10.0.0"}}

    commands = drain_commands()

    assert Enum.any?(commands, fn
             {manager, ["--user", "restart", "codex-loops.service"]} -> manager == fixture.manager
             _other -> false
           end)
  end

  test "backup cleanup failure is a successful install warning, not an outer rollback signal" do
    fixture = fixture()
    assert {:ok, _installed} = Install.run(:install, fixture.opts)
    File.write!(Path.join(fixture.skill_source, "SKILL.md"), "# Updated Codex Loops\n")

    opts = Keyword.put(fixture.opts, :skill_backup_cleanup, fn _path -> {:error, :injected_cleanup_failure} end)
    assert {:ok, updated} = Install.run(:install, opts)
    assert updated["changed"]
    assert updated["plan"] == ["install_skill"]
    assert [%{"code" => "install_cleanup_failed"}] = Enum.map(updated["warnings"], &Map.take(&1, ["code"]))
    assert File.read!(Path.join(fixture.skill_path, "SKILL.md")) == "# Updated Codex Loops\n"
    assert File.read!(fixture.service_path) =~ fixture.release
    assert {:ok, %{"plan" => []}} = Install.run(:check, fixture.opts)
  end

  test "PID/token locks recover dead owners and fail closed for live or malformed owners" do
    fixture = fixture()
    lock = fixture.lock_path
    File.mkdir_p!(lock)
    File.write!(Path.join(lock, "owner.json"), Jason.encode!(%{"pid" => "999999", "token" => String.duplicate("a", 24)}))

    assert :worked = Lock.with_lock(lock, [process_alive: fn "999999" -> false end], fn -> :worked end)
    refute File.exists?(lock)

    File.mkdir_p!(lock)
    File.write!(Path.join(lock, "owner.json"), Jason.encode!(%{"pid" => "42", "token" => String.duplicate("b", 24)}))

    assert {:error, %Error{code: "install_in_progress"}} =
             Lock.with_lock(lock, [process_alive: fn "42" -> true end], fn -> flunk("lock must not run") end)

    File.rm_rf!(lock)
    File.mkdir_p!(lock)
    File.write!(Path.join(lock, "owner.json"), "not-json")

    assert {:error, %Error{code: "install_lock_invalid"}} =
             Lock.with_lock(lock, [process_alive: fn _pid -> false end], fn -> flunk("lock must not run") end)
  end

  test "dead reclaim gates recover while live and malformed gates fail closed" do
    fixture = fixture()
    lock = fixture.lock_path
    gate = lock <> ".reclaim"
    write_lock_owner!(gate, "999999", String.duplicate("d", 24))

    assert :worked = Lock.with_lock(lock, [process_alive: fn "999999" -> false end], fn -> :worked end)
    refute File.exists?(gate)

    write_lock_owner!(gate, "42", String.duplicate("e", 24))

    assert {:error, %Error{code: "install_in_progress"}} =
             Lock.with_lock(lock, [process_alive: fn "42" -> true end], fn -> flunk("lock must not run") end)

    File.rm_rf!(gate)
    File.mkdir_p!(gate)
    File.write!(Path.join(gate, "owner.json"), "not-json")

    assert {:error, %Error{code: "install_lock_invalid"}} =
             Lock.with_lock(lock, [process_alive: fn _pid -> false end], fn -> flunk("lock must not run") end)
  end

  test "unpublished owner storage recovers only when its validated owner is dead" do
    fixture = fixture()
    lock = fixture.lock_path
    dead_token = String.duplicate("f", 24)
    dead_storage = lock <> ".owner." <> dead_token
    write_lock_owner!(dead_storage, "999999", dead_token)

    assert :worked = Lock.with_lock(lock, [process_alive: fn "999999" -> false end], fn -> :worked end)
    refute File.exists?(dead_storage)

    live_token = String.duplicate("g", 24)
    live_storage = lock <> ".owner." <> live_token
    write_lock_owner!(live_storage, "42", live_token)

    assert {:error, %Error{code: "install_in_progress"}} =
             Lock.with_lock(lock, [process_alive: fn "42" -> true end], fn -> flunk("lock must not run") end)

    File.rm_rf!(live_storage)
    malformed_token = String.duplicate("h", 24)
    malformed_storage = lock <> ".owner." <> malformed_token
    File.mkdir_p!(malformed_storage)
    File.write!(Path.join(malformed_storage, "owner.json"), "not-json")

    assert {:error, %Error{code: "install_lock_invalid"}} =
             Lock.with_lock(lock, [process_alive: fn _pid -> false end], fn -> flunk("lock must not run") end)
  end

  test "concurrent installers recover a dead unpublished owner without wedging" do
    fixture = fixture()
    lock = fixture.lock_path
    token = String.duplicate("i", 24)
    storage = lock <> ".owner." <> token
    write_lock_owner!(storage, "999999", token)
    sink = self()

    acquire = fn ->
      Lock.with_lock(
        lock,
        [process_alive: fn pid -> pid != "999999" end],
        fn ->
          send(sink, {:orphan_recovered, self()})

          receive do
            :release_orphan_lock -> :worked
          end
        end
      )
    end

    tasks = [Task.async(acquire), Task.async(acquire)]
    assert_receive {:orphan_recovered, entered}, 1_000
    Process.sleep(20)
    send(entered, :release_orphan_lock)
    results = Enum.map(tasks, &Task.await(&1, 1_000))

    assert Enum.count(results, &(&1 == :worked)) == 1
    assert Enum.count(results, &match?({:error, %Error{code: "install_in_progress"}}, &1)) == 1
    refute File.exists?(lock)
    refute File.exists?(storage)
  end

  test "concurrent installers recover a dead reclaim gate without wedging" do
    fixture = fixture()
    lock = fixture.lock_path
    gate = lock <> ".reclaim"
    write_lock_owner!(gate, "999999", String.duplicate("j", 24))
    sink = self()

    acquire = fn ->
      Lock.with_lock(
        lock,
        [process_alive: fn pid -> pid != "999999" end],
        fn ->
          send(sink, {:gate_recovered, self()})

          receive do
            :release_gate_lock -> :worked
          end
        end
      )
    end

    tasks = [Task.async(acquire), Task.async(acquire)]
    assert_receive {:gate_recovered, entered}, 1_000
    Process.sleep(20)
    send(entered, :release_gate_lock)
    results = Enum.map(tasks, &Task.await(&1, 1_000))

    assert Enum.count(results, &(&1 == :worked)) == 1
    assert Enum.count(results, &match?({:error, %Error{code: "install_in_progress"}}, &1)) == 1
    refute File.exists?(lock)
    refute File.exists?(gate)
  end

  test "only one concurrent reclaimer can replace a dead lock" do
    fixture = fixture()
    lock = fixture.lock_path
    File.mkdir_p!(lock)
    File.write!(Path.join(lock, "owner.json"), Jason.encode!(%{"pid" => "999999", "token" => String.duplicate("c", 24)}))
    sink = self()

    reclaim = fn ->
      Lock.with_lock(
        lock,
        [
          process_alive: fn
            "999999" ->
              send(sink, {:reclaim_probe, self()})

              receive do
                :continue_reclaim -> false
              end

            _live_pid ->
              true
          end
        ],
        fn ->
          send(sink, {:reclaimer_entered, self()})

          receive do
            :release_reclaimer -> :worked
          end
        end
      )
    end

    tasks = [Task.async(reclaim), Task.async(reclaim)]
    assert_receive {:reclaim_probe, probing}, 1_000
    Process.sleep(20)
    send(probing, :continue_reclaim)
    assert_receive {:reclaimer_entered, entered}, 1_000
    send(entered, :release_reclaimer)
    results = Enum.map(tasks, &Task.await(&1, 1_000))

    assert Enum.count(results, &(&1 == :worked)) == 1
    assert Enum.count(results, &match?({:error, %Error{code: "install_in_progress"}}, &1)) == 1
    refute File.exists?(lock)
  end

  defp fixture(state_overrides \\ []) do
    root = Path.join(System.tmp_dir!(), "codex-loops-install-[#{System.unique_integer([:positive])}]")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)

    codex = executable!(Path.join(root, "bin/codex"))
    release = executable!(Path.join(root, "bundle/bin/codex-loops-server"))
    skill_source = Path.join(root, "bundle/share/skills/codex-loops")
    File.mkdir_p!(Path.join(skill_source, "nested"))
    File.write!(Path.join(skill_source, "SKILL.md"), "# Codex Loops\n")
    File.write!(Path.join(skill_source, "nested/.hidden"), "hidden\n")

    service_path = Path.join(root, "home/.config/systemd/user/codex-loops.service")
    binding_path = Path.join(root, "home/.codex/workflows/codex-binding.json")
    skill_path = Path.join(root, "home/.agents/skills/codex-loops")
    lock_path = Path.join(root, "home/.codex/workflows/install.lock")
    manager = "/fake/systemctl"

    state =
      Enum.into(state_overrides, %{
        registration: nil,
        version: "codex-cli 9.9.9",
        fail_current_add?: false,
        manager_active?: false,
        manager_enabled?: false,
        manager_loaded?: false,
        mcp_list_count: 0,
        after_mcp_list: nil,
        after_mcp_list_count: nil,
        mcp_probe_count: 0,
        fail_mcp_probe_at: nil,
        persist_current?: true,
        version_after_add: nil,
        after_current_add: nil
      })

    {:ok, agent} = Agent.start_link(fn -> state end)
    on_exit(fn -> if Process.alive?(agent), do: Agent.stop(agent) end)
    runner = fake_runner(agent, self(), codex)

    opts = [
      home: Path.join(root, "home"),
      codex: codex,
      binding_path: binding_path,
      skill_source: skill_source,
      skill_path: skill_path,
      platform: :linux,
      release_command: release,
      service_path: service_path,
      manager_command: manager,
      command_runner: runner,
      path_env: "/usr/bin:/bin",
      codex_home: nil,
      health_check: fn _url -> if File.regular?(service_path), do: :compatible, else: :unreachable end,
      mcp_endpoint_probe: fn url ->
        send(self(), {:mcp_probe, url})

        {count, fail_at} =
          Agent.get_and_update(agent, fn state ->
            count = state.mcp_probe_count + 1
            {{count, state.fail_mcp_probe_at}, %{state | mcp_probe_count: count}}
          end)

        if count == fail_at,
          do: {:error, Error.new(6, "mcp_endpoint_invalid", "broken endpoint", step: "mcp_endpoint_probe")},
          else: :ok
      end,
      health_timeout: 20,
      health_interval: 1,
      install_lock_path: lock_path
    ]

    %{
      root: root,
      codex: codex,
      release: release,
      skill_source: skill_source,
      service_path: service_path,
      binding_path: binding_path,
      skill_path: skill_path,
      lock_path: lock_path,
      manager: manager,
      agent: agent,
      opts: opts
    }
  end

  defp write_lock_owner!(path, pid, token) do
    File.mkdir_p!(path)
    File.write!(Path.join(path, "owner.json"), Jason.encode!(%{"pid" => pid, "token" => token}))
  end

  defp executable!(path) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "#!/bin/sh\nexit 0\n")
    File.chmod!(path, 0o755)
    path
  end

  defp codex_binding(fixture), do: %CodexBinding{path: fixture.codex, version: "codex-cli 9.9.9"}

  defp fake_runner(agent, sink, codex) do
    fn program, args, _opts ->
      send(sink, {:command, program, args})

      cond do
        program == codex and args == ["--version"] ->
          {:ok, %{status: 0, output: Agent.get(agent, &(&1.version <> "\n"))}}

        program == codex and args == ["mcp", "add", "--help"] ->
          {:ok, %{status: 0, output: "Usage: codex mcp add --url URL\n"}}

        program == codex and args == ["mcp", "list", "--json"] ->
          {servers, hook} =
            Agent.get_and_update(agent, fn state ->
              count = state.mcp_list_count + 1
              servers = if state.registration, do: [state.registration], else: []
              hook = if count == state.after_mcp_list_count, do: state.after_mcp_list
              {{servers, hook}, %{state | mcp_list_count: count}}
            end)

          if is_function(hook, 0), do: hook.()
          {:ok, %{status: 0, output: Jason.encode!(servers)}}

        program == codex and args == ["mcp", "get", "codex-loops", "--json"] ->
          case Agent.get(agent, & &1.registration) do
            nil ->
              {:ok, %{status: 1, output: "No MCP server named 'codex-loops' found."}}

            registration ->
              server =
                registration
                |> Map.delete("auth_status")
                |> Map.put_new("enabled_tools", nil)
                |> Map.put_new("disabled_tools", nil)

              {:ok, %{status: 0, output: Jason.encode!(server)}}
          end

        program == codex and args == ["mcp", "remove", "codex-loops"] ->
          Agent.update(agent, &%{&1 | registration: nil})
          {:ok, %{status: 0, output: ""}}

        program == codex and args == ["mcp", "add", "codex-loops", "--url", MCP.url()] ->
          {result, hook} =
            Agent.get_and_update(agent, fn state ->
              if state.fail_current_add? do
                {{{:ok, %{status: 1, output: "injected add failure"}}, nil}, state}
              else
                registration = if state.persist_current?, do: http_server(MCP.url()), else: state.registration
                version = state.version_after_add || state.version

                {{{:ok, %{status: 0, output: ""}}, state.after_current_add},
                 %{state | registration: registration, version: version}}
              end
            end)

          if is_function(hook, 0), do: hook.()
          result

        program == codex and Enum.take(args, 4) == ["mcp", "add", "codex-loops", "--"] ->
          ["mcp", "add", "codex-loops", "--", command | command_args] = args
          Agent.update(agent, &%{&1 | registration: stdio_server(command, command_args)})
          {:ok, %{status: 0, output: ""}}

        args == ["--user", "is-enabled", "codex-loops.service"] ->
          manager_result(Agent.get(agent, & &1.manager_enabled?))

        args == ["--user", "is-active", "codex-loops.service"] ->
          manager_result(Agent.get(agent, & &1.manager_active?))

        args == ["--user", "enable", "--now", "codex-loops.service"] ->
          Agent.update(agent, &%{&1 | manager_enabled?: true, manager_active?: true})
          {:ok, %{status: 0, output: ""}}

        args == ["--user", "restart", "codex-loops.service"] ->
          Agent.update(agent, &%{&1 | manager_active?: true})
          {:ok, %{status: 0, output: ""}}

        args == ["--user", "disable", "--now", "codex-loops.service"] ->
          Agent.update(agent, &%{&1 | manager_enabled?: false, manager_active?: false})
          {:ok, %{status: 0, output: ""}}

        args == ["--user", "enable", "codex-loops.service"] ->
          Agent.update(agent, &%{&1 | manager_enabled?: true})
          {:ok, %{status: 0, output: ""}}

        args == ["--user", "start", "codex-loops.service"] ->
          Agent.update(agent, &%{&1 | manager_active?: true})
          {:ok, %{status: 0, output: ""}}

        match?(["print", _service], args) ->
          manager_result(Agent.get(agent, & &1.manager_loaded?))

        match?(["bootout", _domain, _definition], args) ->
          Agent.update(agent, &%{&1 | manager_loaded?: false})
          {:ok, %{status: 0, output: ""}}

        match?(["bootstrap", _domain, _definition], args) ->
          Agent.update(agent, &%{&1 | manager_loaded?: true})
          {:ok, %{status: 0, output: ""}}

        true ->
          {:ok, %{status: 0, output: ""}}
      end
    end
  end

  defp manager_result(true), do: {:ok, %{status: 0, output: ""}}
  defp manager_result(false), do: {:ok, %{status: 1, output: ""}}

  defp manager_mutation?({manager, args}, manager) do
    args not in [
      ["--user", "is-enabled", "codex-loops.service"],
      ["--user", "is-active", "codex-loops.service"]
    ]
  end

  defp manager_mutation?(_command, _manager), do: false

  defp server(transport) do
    %{
      "name" => "codex-loops",
      "enabled" => true,
      "disabled_reason" => nil,
      "transport" => transport,
      "startup_timeout_sec" => nil,
      "tool_timeout_sec" => nil,
      "auth_status" => "unsupported"
    }
  end

  defp http_server(url) do
    server(%{
      "type" => "streamable_http",
      "url" => url,
      "bearer_token_env_var" => nil,
      "http_headers" => nil,
      "env_http_headers" => nil
    })
  end

  defp stdio_server(command, args) do
    server(%{
      "type" => "stdio",
      "command" => command,
      "args" => args,
      "env" => nil,
      "env_vars" => [],
      "cwd" => nil
    })
  end

  defp drain_commands(commands \\ []) do
    receive do
      {:command, program, args} -> drain_commands([{program, args} | commands])
    after
      0 -> Enum.reverse(commands)
    end
  end
end
