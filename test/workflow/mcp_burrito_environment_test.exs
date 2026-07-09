defmodule Workflow.MCPBurritoEnvironmentTest do
  use ExUnit.Case, async: false

  alias Workflow.MCP.BurritoEnvironment

  setup do
    previous_plugin_root = System.get_env("CODEX_LOOPS_PLUGIN_ROOT")
    previous_scheduler_bin = System.get_env("CODEX_LOOPS_SCHEDULER_BIN")
    previous_entrypoint = System.get_env("CODEX_LOOPS_ENTRYPOINT")
    previous_burrito_bin = System.get_env("__BURRITO_BIN_PATH")
    previous_burrito = System.get_env("__BURRITO")

    on_exit(fn ->
      restore_env("CODEX_LOOPS_PLUGIN_ROOT", previous_plugin_root)
      restore_env("CODEX_LOOPS_SCHEDULER_BIN", previous_scheduler_bin)
      restore_env("CODEX_LOOPS_ENTRYPOINT", previous_entrypoint)
      restore_env("__BURRITO_BIN_PATH", previous_burrito_bin)
      restore_env("__BURRITO", previous_burrito)
    end)

    System.delete_env("CODEX_LOOPS_PLUGIN_ROOT")
    System.delete_env("CODEX_LOOPS_SCHEDULER_BIN")
    System.delete_env("CODEX_LOOPS_ENTRYPOINT")
    System.delete_env("__BURRITO_BIN_PATH")
    System.delete_env("__BURRITO")

    :ok
  end

  test "infers plugin root from Burrito binary path in the plugin mcp directory" do
    plugin_root = Path.join(System.tmp_dir!(), "codex-loops-plugin")
    bin_path = Path.join([plugin_root, "mcp", "codex-loops-mcp"])
    System.put_env("__BURRITO_BIN_PATH", bin_path)

    assert :ok = BurritoEnvironment.bootstrap()

    assert System.get_env("CODEX_LOOPS_PLUGIN_ROOT") == Path.expand(plugin_root)
  end

  test "preserves explicit plugin root override" do
    explicit = Path.join(System.tmp_dir!(), "explicit-plugin")
    System.put_env("CODEX_LOOPS_PLUGIN_ROOT", explicit)

    System.put_env(
      "__BURRITO_BIN_PATH",
      Path.join([System.tmp_dir!(), "other", "mcp", "codex-loops-mcp"])
    )

    assert :ok = BurritoEnvironment.bootstrap()

    assert System.get_env("CODEX_LOOPS_PLUGIN_ROOT") == explicit
  end

  test "preserves explicit scheduler binary override" do
    scheduler_bin = Path.join(System.tmp_dir!(), "agent_loops")
    System.put_env("CODEX_LOOPS_SCHEDULER_BIN", scheduler_bin)

    System.put_env(
      "__BURRITO_BIN_PATH",
      Path.join([System.tmp_dir!(), "other", "mcp", "codex-loops-mcp"])
    )

    assert :ok = BurritoEnvironment.bootstrap()

    refute System.get_env("CODEX_LOOPS_PLUGIN_ROOT")
  end

  test "uses explicit env var as MCP entrypoint signal" do
    refute BurritoEnvironment.mcp_entrypoint?()

    System.put_env("CODEX_LOOPS_ENTRYPOINT", "mcp")

    assert BurritoEnvironment.mcp_entrypoint?()
  end

  test "uses installed Burrito MCP binary name as MCP entrypoint signal" do
    System.put_env(
      "__BURRITO_BIN_PATH",
      Path.join([System.tmp_dir!(), "codex-loops", "mcp", "codex-loops-mcp"])
    )

    assert BurritoEnvironment.mcp_entrypoint?()
  end

  test "uses Burrito output binary name as MCP entrypoint signal" do
    System.put_env(
      "__BURRITO_BIN_PATH",
      Path.join([System.tmp_dir!(), "codex-loops", "burrito_out", "codex_loops_mcp_native"])
    )

    assert BurritoEnvironment.mcp_entrypoint?()
  end

  test "does not treat an arbitrary Burrito binary as the MCP entrypoint" do
    System.put_env("__BURRITO_BIN_PATH", Path.join(System.tmp_dir!(), "agent_loops"))

    refute BurritoEnvironment.mcp_entrypoint?()
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
