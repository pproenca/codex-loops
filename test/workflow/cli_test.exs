defmodule Workflow.CLITest do
  use ExUnit.Case, async: false

  alias Workflow.CLI
  alias Workflow.Install.CodexBinding
  alias Workflow.Install.Service

  @wrapper Path.expand("../../rel/overlays/bin/codex-loops", __DIR__)

  test "help exposes the one-action installer and service commands" do
    help = CLI.help()
    assert help =~ "install [--codex ABSOLUTE_PATH] [--check | --dry-run] [--json]"

    for command <- ~w[check dry-run serve stop restart status doctor] do
      assert help =~ command
    end
  end

  test "parser failures use the stable CLI envelope and reject undeclared flags" do
    for args <- [
          ["install", "--check", "--dry-run"],
          ["install", "--verbose"],
          ["status", "extra"],
          ["unknown"]
        ] do
      assert {:error, 2,
              %{
                "api_version" => "codex-loops.cli.v1",
                "ok" => false,
                "changed" => false,
                "error" => %{"code" => "usage"}
              }} = CLI.run(args)
    end
  end

  test "dry-run alias returns a stable envelope without mutating any surface" do
    fixture = fixture()

    assert {:ok,
            %{
              "api_version" => "codex-loops.cli.v1",
              "ok" => true,
              "changed" => false,
              "command" => "dry-run",
              "data" => %{"mode" => "dry_run", "plan" => plan}
            }} = CLI.run(["dry-run", "--codex", fixture.codex, "--json"], fixture.opts)

    assert plan == ["bind_codex", "install_service", "install_skill", "add_mcp"]
    refute File.exists?(fixture.binding_path)
    refute File.exists?(fixture.service_path)
    refute File.exists?(fixture.skill_path)
  end

  test "stop and status remain usable when the recorded Codex executable moved" do
    fixture = fixture()
    binding = %CodexBinding{path: fixture.codex, version: "codex-cli 9.9.9"}
    assert :ok = CodexBinding.persist(binding, fixture.opts)
    assert {:ok, service} = Service.config(binding, fixture.opts)
    File.mkdir_p!(Path.dirname(fixture.service_path))
    File.write!(fixture.service_path, service.content)
    File.rm!(fixture.codex)

    assert {:ok, %{"command" => "status", "data" => %{"state" => "current"}}} =
             CLI.run(["status"], fixture.opts)

    assert {:ok, %{"command" => "stop", "data" => %{"state" => "stopped"}}} =
             CLI.run(["stop"], fixture.opts)

    assert {:error, 3, %{"error" => %{"code" => "codex_binding_invalid"}}} =
             CLI.run(["serve"], fixture.opts)
  end

  test "packaged launcher resolves top-level symlinks and ignores ambient source overrides" do
    root = Path.join(System.tmp_dir!(), "codex-loops-wrapper-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(root) end)
    wrapper = Path.join(root, "bundle/bin/codex-loops")
    release_bin = Path.join(root, "bundle/libexec/scheduler/bin")
    skill = Path.join(root, "bundle/share/skills/codex-loops")
    File.mkdir_p!(Path.dirname(wrapper))
    File.mkdir_p!(release_bin)
    File.mkdir_p!(skill)
    File.cp!(@wrapper, wrapper)
    File.chmod!(wrapper, 0o755)
    File.write!(Path.join(skill, "SKILL.md"), "# bundled\n")
    executable!(Path.join(release_bin, "codex-loops-server"))

    agent_loops = Path.join(release_bin, "agent_loops")

    File.write!(
      agent_loops,
      ~s(#!/bin/sh\nprintf 'release=%s\\n' "$CODEX_LOOPS_RELEASE_COMMAND"\nprintf 'skill=%s\\n' "$CODEX_LOOPS_SKILL_SOURCE"\nprintf 'args='\nprintf '<%s>' "$@"\nprintf '\\n'\n)
    )

    File.chmod!(agent_loops, 0o755)
    link = Path.join(root, "linked/codex-loops")
    File.mkdir_p!(Path.dirname(link))
    File.ln_s!(wrapper, link)

    {output, 0} =
      System.cmd(link, ["--version"],
        env: [
          {"CODEX_LOOPS_RELEASE_COMMAND", "/evil/server"},
          {"CODEX_LOOPS_SKILL_SOURCE", "/evil/skill"}
        ]
      )

    assert output =~ "/bundle/libexec/scheduler/bin/codex-loops-server"
    assert output =~ "/bundle/share/skills/codex-loops"
    refute output =~ "/evil/"
    assert output =~ "<eval><Workflow.CLI.main(System.argv())><--version>"
  end

  test "packaged launcher bounds cyclic symlink resolution" do
    root = Path.join(System.tmp_dir!(), "codex-loops-wrapper-cycle-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(root) end)
    File.mkdir_p!(root)
    first = Path.join(root, "first")
    second = Path.join(root, "second")
    File.ln_s!(second, first)
    File.ln_s!(first, second)

    {output, status} =
      System.cmd("/bin/sh", ["-c", ". \"$WRAPPER\"", first],
        env: [{"WRAPPER", @wrapper}],
        stderr_to_stdout: true
      )

    assert status == 3
    assert output =~ "symlink traversal exceeded 40 links"
  end

  defp fixture do
    root = Path.join(System.tmp_dir!(), "codex-loops-cli-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)

    codex = executable!(Path.join(root, "bin/codex"))
    release = executable!(Path.join(root, "bundle/bin/codex-loops-server"))
    skill_source = Path.join(root, "bundle/share/skills/codex-loops")
    File.mkdir_p!(skill_source)
    File.write!(Path.join(skill_source, "SKILL.md"), "# Codex Loops\n")
    service_path = Path.join(root, "home/.config/systemd/user/codex-loops.service")
    binding_path = Path.join(root, "home/.codex/workflows/codex-binding.json")
    skill_path = Path.join(root, "home/.agents/skills/codex-loops")

    runner = fn program, args, _opts ->
      case {program, args} do
        {^codex, ["--version"]} -> {:ok, %{status: 0, output: "codex-cli 9.9.9\n"}}
        {^codex, ["mcp", "add", "--help"]} -> {:ok, %{status: 0, output: "--url\n"}}
        {^codex, ["mcp", "list", "--json"]} -> {:ok, %{status: 0, output: "[]"}}
        _manager_command -> {:ok, %{status: 0, output: ""}}
      end
    end

    opts = [
      home: Path.join(root, "home"),
      binding_path: binding_path,
      skill_source: skill_source,
      skill_path: skill_path,
      platform: :linux,
      release_command: release,
      service_path: service_path,
      manager_command: "/fake/systemctl",
      command_runner: runner,
      path_env: "/usr/bin:/bin",
      codex_home: nil,
      health_check: fn _url -> if File.regular?(service_path), do: :compatible, else: :unreachable end,
      mcp_endpoint_probe: fn _url -> :ok end,
      install_lock_path: Path.join(root, "home/.codex/workflows/install.lock")
    ]

    %{
      codex: codex,
      service_path: service_path,
      binding_path: binding_path,
      skill_path: skill_path,
      opts: opts
    }
  end

  defp executable!(path) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "#!/bin/sh\nexit 0\n")
    File.chmod!(path, 0o755)
    path
  end
end
