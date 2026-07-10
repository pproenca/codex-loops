defmodule Workflow.PluginLauncherTest do
  use ExUnit.Case, async: true

  @launcher Path.expand("../../plugins/codex-loops/mcp/codex-loops-mcp", __DIR__)
  @version Workflow.PackageVersion.version()

  test "executes a compatible runtime from CODEX_LOOPS_RUNTIME_ROOT" do
    runtime_root = runtime_fixture(@version)

    assert {output, 0} =
             System.cmd("/bin/sh", [@launcher, "--stdio"], env: [{"CODEX_LOOPS_RUNTIME_ROOT", runtime_root}])

    assert output == "runtime --stdio\n"
  end

  test "a cached source plugin discovers builds from its configured local marketplace" do
    source_root = tmp_dir("source")
    cache_root = tmp_dir("cache")
    plugin_root = Path.join(cache_root, "plugins/codex-loops")
    launcher = Path.join(plugin_root, "mcp/codex-loops-mcp")
    mcp = Path.join(source_root, "native/codex-loops/target/release/codex-loops-mcp")
    scheduler = Path.join(source_root, "_build/prod/rel/agent_loops/bin/agent_loops")
    fake_bin = Path.join(cache_root, "bin")
    codex = Path.join(fake_bin, "codex")

    File.mkdir_p!(Path.dirname(launcher))
    File.mkdir_p!(Path.join(plugin_root, ".codex-plugin"))
    File.mkdir_p!(Path.dirname(mcp))
    File.mkdir_p!(Path.dirname(scheduler))
    File.mkdir_p!(fake_bin)
    File.write!(Path.join(source_root, "mix.exs"), "source checkout")
    File.write!(Path.join(source_root, "native/codex-loops/Cargo.toml"), "source checkout")
    File.cp!(@launcher, launcher)

    File.cp!(
      Path.join(Path.dirname(@launcher), "../.codex-plugin/plugin.json"),
      Path.join(plugin_root, ".codex-plugin/plugin.json")
    )

    File.write!(
      mcp,
      "#!/bin/sh\nif [ \"$1\" = \"--version\" ]; then echo 'codex-loops-mcp #{@version}'; else echo \"source $* scheduler=$CODEX_LOOPS_SCHEDULER_BIN\"; fi\n"
    )

    File.write!(scheduler, "#!/bin/sh\nexit 0\n")
    File.write!(codex, "#!/bin/sh\nprintf 'MARKETPLACE  ROOT\\ncodex-loops  %s\\n' '#{source_root}'\n")
    File.chmod!(launcher, 0o755)
    File.chmod!(mcp, 0o755)
    File.chmod!(scheduler, 0o755)
    File.chmod!(codex, 0o755)

    on_exit(fn ->
      File.rm_rf(source_root)
      File.rm_rf(cache_root)
    end)

    assert {output, 0} =
             System.cmd("/bin/sh", [launcher, "--stdio"],
               cd: plugin_root,
               env: [
                 {"CODEX_LOOPS_RUNTIME_ROOT", nil},
                 {"CODEX_LOOPS_MCP_BIN", nil},
                 {"CODEX_LOOPS_SCHEDULER_BIN", nil},
                 {"PATH", "#{fake_bin}:/usr/bin:/bin"}
               ]
             )

    assert output == "source --stdio scheduler=#{scheduler}\n"
  end

  test "fails with source-build guidance when the runtime is missing" do
    missing_root = tmp_dir("missing")

    assert {output, 1} =
             System.cmd("/bin/sh", [@launcher, "--stdio"],
               env: [
                 {"CODEX_LOOPS_RUNTIME_ROOT", missing_root},
                 {"CODEX_LOOPS_MCP_BIN", nil},
                 {"PATH", "/usr/bin:/bin"}
               ],
               stderr_to_stdout: true
             )

    assert output =~ "CODEX_LOOPS_RUNTIME_ROOT is set but does not contain a usable"
    assert output =~ "Homebrew tap is not published yet"
    assert output =~ "make package-homebrew-runtime"
  end

  test "fails closed when plugin and runtime versions differ" do
    runtime_root = runtime_fixture("99.0.0")

    assert {output, 1} =
             System.cmd("/bin/sh", [@launcher, "--stdio"],
               env: [{"CODEX_LOOPS_RUNTIME_ROOT", runtime_root}],
               stderr_to_stdout: true
             )

    assert output =~ "plugin/runtime version mismatch"
    assert output =~ "Plugin:  #{@version}"
    assert output =~ "Runtime: 99.0.0"
  end

  test "discovers a Homebrew command shim on PATH" do
    prefix = tmp_dir("prefix")
    runtime_root = Path.join(prefix, "opt/codex-loops/libexec")
    File.mkdir_p!(Path.join(prefix, "bin"))
    File.mkdir_p!(Path.dirname(runtime_root))
    File.ln_s!(runtime_fixture(@version), runtime_root)

    shim = Path.join(prefix, "bin/codex-loops-mcp")

    File.write!(shim, """
    #!/bin/sh
    exec "#{runtime_root}/mcp/codex-loops-mcp" "$@"
    """)

    File.chmod!(shim, 0o755)
    on_exit(fn -> File.rm_rf(prefix) end)

    assert {output, 0} =
             System.cmd("/bin/sh", [@launcher, "--stdio"],
               env: [
                 {"CODEX_LOOPS_RUNTIME_ROOT", nil},
                 {"CODEX_LOOPS_MCP_BIN", nil},
                 {"PATH", "#{prefix}/bin:/usr/bin:/bin"}
               ]
             )

    assert output == "runtime --stdio\n"
  end

  test "supports explicit MCP and scheduler paths for custom installs" do
    runtime_root = runtime_fixture(@version)
    mcp = Path.join(runtime_root, "mcp/codex-loops-mcp")
    scheduler = Path.join(runtime_root, "scheduler/bin/agent_loops")

    assert {output, 0} =
             System.cmd("/bin/sh", [@launcher, "--stdio"],
               env: [
                 {"CODEX_LOOPS_RUNTIME_ROOT", nil},
                 {"CODEX_LOOPS_MCP_BIN", mcp},
                 {"CODEX_LOOPS_SCHEDULER_BIN", scheduler}
               ]
             )

    assert output == "runtime --stdio\n"
  end

  defp runtime_fixture(version) do
    root = tmp_dir("runtime")
    mcp = Path.join(root, "mcp/codex-loops-mcp")
    scheduler = Path.join(root, "scheduler/bin/agent_loops")

    File.mkdir_p!(Path.dirname(mcp))
    File.mkdir_p!(Path.dirname(scheduler))

    File.write!(mcp, """
    #!/bin/sh
    if [ "${1:-}" = "--version" ]; then
      echo "codex-loops-mcp #{version}"
    else
      echo "runtime $*"
    fi
    """)

    File.write!(scheduler, "#!/bin/sh\nexit 0\n")
    File.chmod!(mcp, 0o755)
    File.chmod!(scheduler, 0o755)
    on_exit(fn -> File.rm_rf(root) end)
    root
  end

  defp tmp_dir(name) do
    Path.join(
      System.tmp_dir!(),
      "codex-loops-launcher-#{name}-#{System.unique_integer([:positive])}"
    )
  end
end
