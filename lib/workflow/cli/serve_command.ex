defmodule Workflow.CLI.ServeCommand do
  @moduledoc "Starts the packaged scheduler with local, user-facing defaults."

  import Bitwise, only: [band: 2]

  alias Workflow.CLI
  alias Workflow.MCP.SchedulerClient

  @default_host "127.0.0.1"
  @default_port 47_125

  @type result :: {:ok, map()} | {:error, 1..6, map()}

  @spec run([String.t()], keyword()) :: result()
  def run(args, opts \\ []) do
    with {:ok, config} <- parse(args),
         {:ok, scheduler_bin} <- scheduler_bin(opts),
         {:ok, started?} <- ensure_running(scheduler_bin, config, opts),
         :ok <- announce(config, started?, opts) do
      {:ok,
       %{
         ok: true,
         command: :serve,
         server_url: server_url(config),
         host: config.host,
         port: config.port,
         state: :running,
         started: started?
       }}
    end
  end

  @spec stop([String.t()], keyword()) :: result()
  def stop(args, opts \\ []) do
    with {:ok, config} <- parse_stop(args),
         {:ok, scheduler_bin} <- scheduler_bin(opts),
         {:ok, stopped?} <- ensure_stopped(scheduler_bin, config, opts) do
      {:ok,
       %{
         ok: true,
         command: :stop,
         server_url: server_url(config),
         host: config.host,
         port: config.port,
         state: :stopped,
         stopped: stopped?
       }}
    end
  end

  defp parse_stop(args) do
    {flags, positional, invalid} = OptionParser.parse(args, strict: [json: :boolean])

    cond do
      invalid != [] ->
        usage_error("Unknown stop option: #{invalid |> hd() |> elem(0)}", :stop)

      positional != [] ->
        usage_error("stop does not accept positional arguments.", :stop)

      true ->
        {:ok,
         %{
           host: @default_host,
           port: @default_port,
           journal: nil,
           model: nil,
           json?: flags[:json] || false
         }}
    end
  end

  defp parse(args) do
    {flags, positional, invalid} =
      OptionParser.parse(args,
        strict: [host: :string, port: :integer, journal: :string, model: :string, json: :boolean]
      )

    host = Keyword.get(flags, :host, @default_host)
    port = Keyword.get(flags, :port, @default_port)

    cond do
      invalid != [] ->
        usage_error("Unknown serve option: #{invalid |> hd() |> elem(0)}", :serve)

      positional != [] ->
        usage_error("serve does not accept positional arguments.", :serve)

      not valid_host?(host) ->
        usage_error("--host must be an IP address or localhost.", :serve)

      port not in 1..65_535 ->
        usage_error("--port must be between 1 and 65535.", :serve)

      true ->
        {:ok,
         %{
           host: host,
           port: port,
           journal: flags[:journal],
           model: flags[:model],
           json?: flags[:json] || false
         }}
    end
  end

  defp scheduler_bin(opts) do
    candidate =
      Keyword.get(opts, :scheduler_bin) ||
        System.get_env("CODEX_LOOPS_SCHEDULER_BIN") ||
        runtime_scheduler_bin()

    if executable?(candidate) do
      {:ok, Path.expand(candidate)}
    else
      CLI.error(
        6,
        "runtime_invalid",
        "The packaged scheduler was not found. Build or reinstall Codex Loops first.",
        %{scheduler_bin: candidate}
      )
    end
  end

  defp runtime_scheduler_bin do
    case System.get_env("CODEX_LOOPS_RUNTIME_ROOT") do
      nil -> nil
      "" -> nil
      root -> Path.join([root, "scheduler", "bin", "agent_loops"])
    end
  end

  defp announce(config, started?, opts) do
    announcer =
      if config.json? do
        fn _server -> :ok end
      else
        Keyword.get(opts, :announce, &default_announce/1)
      end

    announcer.(%{
      server_url: server_url(config),
      journal: config.journal,
      model: config.model,
      started: started?
    })
  end

  defp default_announce(server) do
    state = if server.started, do: "started", else: "already running"

    IO.puts("""
    Codex Loops #{state} at #{server.server_url}
    Stop it later with: codex-loops stop
    """)
  end

  defp ensure_running(scheduler_bin, config, opts) do
    if healthy?(config, opts) do
      if runtime_overrides?(config) do
        CLI.error(
          2,
          "scheduler_already_running",
          "Codex Loops is already running, so --journal and --model cannot be applied. Stop it first with: codex-loops stop"
        )
      else
        {:ok, false}
      end
    else
      with :ok <- command(scheduler_bin, "daemon", config, opts),
           :ok <- wait_for(config, opts, & &1) do
        {:ok, true}
      end
    end
  end

  defp ensure_stopped(scheduler_bin, config, opts) do
    case command(scheduler_bin, "stop", config, opts) do
      :ok -> {:ok, true}
      {:error, _status, _error} = failure -> if healthy?(config, opts), do: failure, else: {:ok, false}
    end
  end

  defp runtime_overrides?(config), do: config.journal not in [nil, ""] or config.model not in [nil, ""]

  defp command(scheduler_bin, action, config, opts) do
    runner = Keyword.get(opts, :command, &System.cmd/3)

    {output, status} =
      runner.(
        scheduler_bin,
        [action],
        cd: scheduler_bin |> Path.dirname() |> Path.join("../..") |> Path.expand(),
        env: command_env(config),
        stderr_to_stdout: true
      )

    command_status(status, output)
  end

  defp command_env(config) do
    [
      {"CODEX_LOOPS_SERVER", "1"},
      {"CODEX_LOOPS_HOST", config.host},
      {"CODEX_LOOPS_PORT", Integer.to_string(config.port)},
      {"PORT", Integer.to_string(config.port)},
      {"RELEASE_DISTRIBUTION", "sname"},
      {"RELEASE_NODE", "codex_loops"},
      {"ROOTDIR", nil},
      {"BINDIR", nil},
      {"RELEASE_ROOT", nil},
      {"RELEASE_SYS_CONFIG", nil},
      {"RELEASE_TMP", nil}
    ]
    |> maybe_put("CODEX_LOOPS_JOURNAL_PATH", config.journal && Path.expand(config.journal))
    |> maybe_put("CODEX_LOOPS_CODEX_MODEL", config.model)
  end

  defp command_status(0, _output), do: :ok

  defp command_status(status, output) do
    CLI.error(6, "scheduler_start_failed", "The scheduler exited unexpectedly.", %{
      status: status,
      output: String.trim(output)
    })
  end

  defp wait_for(config, opts, predicate, attempts \\ 100)

  defp wait_for(_config, _opts, _predicate, 0) do
    CLI.error(6, "scheduler_timeout", "The scheduler did not reach the expected lifecycle state.")
  end

  defp wait_for(config, opts, predicate, attempts) do
    if predicate.(healthy?(config, opts)) do
      :ok
    else
      sleep = Keyword.get(opts, :sleep, &Process.sleep/1)
      sleep.(100)
      wait_for(config, opts, predicate, attempts - 1)
    end
  end

  defp healthy?(config, opts) do
    case Keyword.get(opts, :health) do
      nil -> match?({:ok, _payload}, SchedulerClient.health(base_url: server_url(config)))
      health -> health.() == :ok
    end
  end

  defp server_url(config), do: SchedulerClient.local_base_url(config.host, config.port)

  defp valid_host?("localhost"), do: true

  defp valid_host?(host) do
    match?({:ok, _address}, :inet.parse_address(String.to_charlist(host)))
  end

  defp executable?(path) when is_binary(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, mode: mode}} -> band(mode, 0o111) != 0
      _other -> false
    end
  end

  defp executable?(_path), do: false

  defp maybe_put(env, _key, nil), do: env
  defp maybe_put(env, _key, ""), do: env
  defp maybe_put(env, key, value), do: [{key, value} | env]

  defp usage_error(message, command), do: CLI.error(2, "usage", message <> "\n\n" <> usage(command))

  defp usage(:serve) do
    "Usage: codex-loops serve [--host HOST] [--port PORT] [--journal PATH] [--model MODEL]"
  end

  defp usage(:stop), do: "Usage: codex-loops stop"
end
