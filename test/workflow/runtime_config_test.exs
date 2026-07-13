defmodule Workflow.RuntimeConfigTest do
  use ExUnit.Case, async: false

  alias Workflow.Web.Endpoint

  @runtime_config Path.expand("../../config/runtime.exs", __DIR__)
  @env_keys ~w(
    CODEX_LOOPS_BINDING_PATH
    CODEX_LOOPS_CODEX_BIN
    CODEX_LOOPS_CODEX_MODEL
    CODEX_LOOPS_CODEX_SANDBOX
    CODEX_LOOPS_CODEX_WORKDIR
    CODEX_LOOPS_HOST
    CODEX_LOOPS_PORT
    CODEX_LOOPS_SERVER
    PORT
  )

  setup do
    previous = Map.new(@env_keys, &{&1, System.get_env(&1)})
    Enum.each(@env_keys, &System.delete_env/1)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end)

    :ok
  end

  test "production defaults are local, bounded, and signed with an ephemeral secret" do
    endpoint = runtime_config()[:codex_loops][Endpoint]

    assert endpoint[:http] == [ip: {127, 0, 0, 1}, port: 4000]
    assert endpoint[:url] == [host: "127.0.0.1", port: 4000]
    assert endpoint[:server] == false
    assert byte_size(endpoint[:secret_key_base]) >= 64
  end

  test "server mode accepts only its closed boolean vocabulary" do
    for value <- ["yes", "TRUE", "2", ""] do
      System.put_env("CODEX_LOOPS_SERVER", value)

      assert_raise RuntimeError, ~r/invalid CODEX_LOOPS_SERVER/, fn ->
        runtime_config()
      end
    end
  end

  test "the scheduler port is an integer in the TCP port range" do
    for value <- ["0", "65536", "-1", "4000x", ""] do
      System.put_env("CODEX_LOOPS_PORT", value)

      assert_raise RuntimeError, ~r/invalid scheduler port/, fn ->
        runtime_config()
      end
    end
  end

  test "CODEX_LOOPS_PORT overrides PORT after both are validated" do
    System.put_env("PORT", "4100")
    assert runtime_config()[:codex_loops][Endpoint][:http][:port] == 4100

    System.put_env("CODEX_LOOPS_PORT", "4200")
    assert runtime_config()[:codex_loops][Endpoint][:http][:port] == 4200
  end

  test "production binding accepts only IPv4 and IPv6 loopback hosts" do
    for {host, expected_ip} <- [
          {"localhost", {127, 0, 0, 1}},
          {"LOCALhost", {127, 0, 0, 1}},
          {"127.0.0.2", {127, 0, 0, 2}},
          {"::1", {0, 0, 0, 0, 0, 0, 0, 1}}
        ] do
      System.put_env("CODEX_LOOPS_HOST", host)
      assert runtime_config()[:codex_loops][Endpoint][:http][:ip] == expected_ip
    end

    for host <- ["0.0.0.0", "::", "192.0.2.1", "example.com", "localhost."] do
      System.put_env("CODEX_LOOPS_HOST", host)

      assert_raise RuntimeError, ~r/Expected localhost or a numeric IPv4\/IPv6 loopback address/, fn ->
        runtime_config()
      end
    end
  end

  test "server mode requires an absolute executable and binding path from the managed service" do
    System.put_env("CODEX_LOOPS_SERVER", "true")

    assert_raise RuntimeError, ~r/CODEX_LOOPS_CODEX_BIN must be injected by the Codex Loops managed service/, fn ->
      runtime_config()
    end

    System.put_env("CODEX_LOOPS_CODEX_BIN", "codex")

    assert_raise RuntimeError, ~r/must name an absolute executable file/, fn ->
      runtime_config()
    end

    executable = System.find_executable("true")
    System.put_env("CODEX_LOOPS_CODEX_BIN", executable)

    assert_raise RuntimeError, ~r/CODEX_LOOPS_BINDING_PATH must be injected/, fn ->
      runtime_config()
    end

    System.put_env("CODEX_LOOPS_BINDING_PATH", "relative")

    assert_raise RuntimeError, ~r/CODEX_LOOPS_BINDING_PATH must name an absolute path/, fn ->
      runtime_config()
    end

    binding_path = Path.join(System.tmp_dir!(), "codex-loops-binding.json")
    System.put_env("CODEX_LOOPS_BINDING_PATH", binding_path)
    config = runtime_config()[:codex_loops]
    assert config[:codex_command] == {executable, []}
    assert config[:codex_binding_path] == binding_path
  end

  test "the optional Codex model is trimmed once and may not be blank" do
    System.put_env("CODEX_LOOPS_CODEX_MODEL", "   ")

    assert_raise RuntimeError, ~r/CODEX_LOOPS_CODEX_MODEL must not be blank/, fn ->
      runtime_config()
    end

    System.put_env("CODEX_LOOPS_CODEX_MODEL", " gpt-test ")
    assert runtime_config()[:codex_loops][:codex_model] == "gpt-test"
  end

  test "sandboxed Codex execution requires a workspace-write mode and absolute directory" do
    System.put_env("CODEX_LOOPS_CODEX_SANDBOX", "workspace-write")

    assert_raise RuntimeError, ~r/invalid Codex sandbox configuration/, fn ->
      runtime_config()
    end

    System.put_env("CODEX_LOOPS_CODEX_WORKDIR", "relative")

    assert_raise RuntimeError, ~r/must name an absolute directory/, fn ->
      runtime_config()
    end

    System.put_env("CODEX_LOOPS_CODEX_WORKDIR", System.tmp_dir!())

    assert runtime_config()[:codex_loops][:codex_execution] ==
             {:sandboxed, System.tmp_dir!()}
  end

  defp runtime_config do
    Config.Reader.read!(@runtime_config, env: :prod, target: :host)
  end
end
