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

  test "fails with install guidance when the runtime is missing" do
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
    assert output =~ "brew install pproenca/codex-loops/codex-loops"
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
