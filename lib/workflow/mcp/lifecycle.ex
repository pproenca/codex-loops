defmodule Workflow.MCP.Lifecycle do
  @moduledoc """
  Scheduler lifecycle helper for the MCP adapter.

  The adapter may own a packaged scheduler OS process, but it never owns
  workflow state. All workflow behavior stays behind the scheduler HTTP API.
  """

  alias Workflow.MCP.SchedulerClient
  import Bitwise, only: [band: 2]

  @api_version "codex-loops.mcp.v1"

  @type state :: %{
          required(:owned_scheduler) => nil | map(),
          required(:release_counter) => non_neg_integer()
        }

  @spec new() :: state()
  def new, do: %{owned_scheduler: nil, release_counter: 0}

  @spec ensure_ready(state()) :: {:ok, state()} | {:error, map(), state()}
  def ensure_ready(state) do
    case SchedulerClient.health() do
      {:ok, _payload} ->
        {:ok, state}

      {:error, reason} ->
        start_or_report(state, reason)
    end
  end

  @spec stop_owned(state()) :: state()
  def stop_owned(%{owned_scheduler: nil} = state), do: state

  def stop_owned(%{owned_scheduler: scheduler} = state) do
    {_output, _status} =
      System.cmd(scheduler.release_bin, ["stop"],
        cd: scheduler.cwd,
        env: scheduler.env,
        stderr_to_stdout: true
      )

    scheduler = wait_for_port_exit(scheduler, 50)

    if Process.alive?(self()) and not port_exited?(scheduler) do
      Port.close(scheduler.port)
    end

    %{state | owned_scheduler: nil}
  rescue
    _error -> %{state | owned_scheduler: nil}
  end

  @spec collect_port_messages(state()) :: state()
  def collect_port_messages(%{owned_scheduler: nil} = state), do: state

  def collect_port_messages(%{owned_scheduler: scheduler} = state) do
    %{state | owned_scheduler: collect_scheduler_messages(scheduler)}
  end

  defp start_or_report(state, health_error) do
    config = SchedulerClient.config()

    cond do
      not local_autostart?(config) ->
        {:error,
         unavailable(%{
           scheduler_url: config.base_url,
           reason:
             "Configured scheduler URL is not local, so this MCP adapter cannot auto-start a packaged scheduler for it.",
           last_error: health_error,
           next_steps: [
             "Point CODEX_LOOPS_SCHEDULER_URL at a reachable scheduler.",
             "Or use CODEX_LOOPS_SCHEDULER_HOST/CODEX_LOOPS_SCHEDULER_PORT with a local loopback address to enable auto-start."
           ]
         }), state}

      running_owned?(state) ->
        wait_for_health(state)

      true ->
        case start_owned_scheduler(state, health_error) do
          {:ok, started_state} -> wait_for_health(started_state)
          {:error, envelope, next_state} -> {:error, envelope, next_state}
        end
    end
  end

  defp wait_for_health(state) do
    Enum.reduce_while(1..100, state, fn _attempt, acc ->
      acc = collect_port_messages(acc)

      case SchedulerClient.health() do
        {:ok, _payload} ->
          {:halt, {:ok, acc}}

        {:error, reason} ->
          case acc.owned_scheduler do
            nil ->
              {:halt, {:error, unavailable(%{reason: reason}), acc}}

            scheduler ->
              if port_exited?(scheduler) do
                {:halt,
                 {:error,
                  start_failed(%{
                    scheduler_url: SchedulerClient.config().base_url,
                    release_bin: scheduler.release_bin,
                    reason: "Scheduler release exited before becoming healthy.",
                    exit_status: scheduler.exit_status,
                    logs: Enum.take(scheduler.logs, -20)
                  }), acc}}
              else
                Process.sleep(100)
                {:cont, acc}
              end
          end
      end
    end)
    |> case do
      {:ok, state} ->
        {:ok, state}

      {:error, envelope, state} ->
        {:error, envelope, state}

      state ->
        scheduler = state.owned_scheduler

        {:error,
         unavailable(%{
           scheduler_url: SchedulerClient.config().base_url,
           reason: "Scheduler did not become healthy after start.",
           attempted_release_bin: scheduler && scheduler.release_bin,
           logs: if(scheduler, do: Enum.take(scheduler.logs, -20), else: [])
         }), state}
    end
  end

  defp start_owned_scheduler(state, health_error) do
    case discover_release() do
      {:ok, release_bin, candidates} ->
        do_start_owned_scheduler(state, release_bin, candidates)

      {:error, candidates} ->
        {:error,
         unavailable(%{
           scheduler_url: SchedulerClient.config().base_url,
           reason: "No packaged scheduler release was found.",
           last_error: health_error,
           searched_paths: candidates,
           next_steps: [
             "Build the release with `make release`.",
             "Or set CODEX_LOOPS_SCHEDULER_BIN to an executable scheduler release script."
           ]
         }), state}
    end
  end

  defp do_start_owned_scheduler(state, release_bin, _candidates) do
    config = SchedulerClient.config()

    release_tmp =
      Path.join(
        System.tmp_dir!(),
        "codex-loops-mcp-release-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(release_tmp)

    release_node = "agent_loops_mcp_#{System.os_time(:millisecond)}_#{state.release_counter}"
    cwd = repo_root()

    env =
      [
        {"CODEX_LOOPS_SERVER", "1"},
        {"CODEX_LOOPS_HOST", config.host},
        {"CODEX_LOOPS_PORT", Integer.to_string(config.port)},
        {"PORT", Integer.to_string(config.port)},
        {"RELEASE_DISTRIBUTION", "sname"},
        {"RELEASE_NODE", release_node},
        {"RELEASE_TMP", release_tmp}
      ]
      |> maybe_put_env("CODEX_LOOPS_JOURNAL_PATH")

    port =
      Port.open({:spawn_executable, release_bin}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        {:args, ["start"]},
        {:cd, cwd},
        {:env, port_env(env)}
      ])

    scheduler = %{
      port: port,
      release_bin: release_bin,
      cwd: cwd,
      env: env,
      logs: [],
      exit_status: nil
    }

    state = %{state | owned_scheduler: scheduler, release_counter: state.release_counter + 1}
    Process.sleep(100)

    state = collect_port_messages(state)

    if port_exited?(state.owned_scheduler) do
      {:error,
       start_failed(%{
         scheduler_url: config.base_url,
         release_bin: release_bin,
         exit_status: state.owned_scheduler.exit_status,
         logs: state.owned_scheduler.logs
       }), state}
    else
      {:ok, state}
    end
  rescue
    error ->
      {:error,
       start_failed(%{
         scheduler_url: SchedulerClient.config().base_url,
         release_bin: release_bin,
         reason: Exception.message(error)
       }), state}
  end

  defp collect_scheduler_messages(scheduler) do
    receive do
      {port, {:data, data}} when port == scheduler.port ->
        scheduler
        |> append_logs(data)
        |> collect_scheduler_messages()

      {port, {:exit_status, status}} when port == scheduler.port ->
        %{scheduler | exit_status: status}
    after
      0 -> scheduler
    end
  end

  defp wait_for_port_exit(scheduler, 0), do: collect_scheduler_messages(scheduler)

  defp wait_for_port_exit(scheduler, attempts_left) do
    scheduler = collect_scheduler_messages(scheduler)

    if port_exited?(scheduler) do
      scheduler
    else
      Process.sleep(100)
      wait_for_port_exit(scheduler, attempts_left - 1)
    end
  end

  defp append_logs(scheduler, data) do
    lines =
      data
      |> to_string()
      |> String.split(~r/\r?\n/u, trim: true)
      |> Enum.map(&String.trim_trailing/1)

    %{scheduler | logs: Enum.take(scheduler.logs ++ lines, -200)}
  end

  defp port_exited?(nil), do: true

  defp port_exited?(%{exit_status: status}) when is_integer(status), do: true

  defp port_exited?(%{port: port}) do
    Port.info(port) == nil
  end

  defp running_owned?(%{owned_scheduler: nil}), do: false
  defp running_owned?(%{owned_scheduler: scheduler}), do: not port_exited?(scheduler)

  defp discover_release do
    candidates =
      [
        System.get_env("CODEX_LOOPS_SCHEDULER_BIN"),
        Path.join([plugin_root(), "scheduler", "bin", "agent_loops"]),
        Path.join([repo_root(), "_build", "prod", "rel", "agent_loops", "bin", "agent_loops"])
      ]
      |> Enum.reject(&is_nil_or_empty?/1)
      |> Enum.map(&Path.expand/1)

    case Enum.find(candidates, &executable_file?/1) do
      nil -> {:error, candidates}
      release_bin -> {:ok, release_bin, candidates}
    end
  end

  defp executable_file?(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, mode: mode}} -> band(mode, 0o111) != 0
      _other -> false
    end
  end

  defp local_autostart?(%{protocol: "http:", host: host}) do
    host in ["localhost", "127.0.0.1", "::1"] or String.starts_with?(host, "127.")
  end

  defp local_autostart?(_config), do: false

  defp plugin_root do
    System.get_env("CODEX_LOOPS_PLUGIN_ROOT") ||
      Path.expand("plugins/codex-loops", File.cwd!())
  end

  defp repo_root do
    System.get_env("CODEX_LOOPS_REPO_ROOT") ||
      plugin_root()
      |> Path.join("../..")
      |> Path.expand()
  end

  defp maybe_put_env(env, key) do
    case System.get_env(key) do
      nil -> env
      "" -> env
      value -> [{key, value} | env]
    end
  end

  defp is_nil_or_empty?(nil), do: true
  defp is_nil_or_empty?(""), do: true
  defp is_nil_or_empty?(_value), do: false

  defp port_env(env) do
    Enum.map(env, fn {key, value} -> {String.to_charlist(key), String.to_charlist(value)} end)
  end

  defp unavailable(details) do
    %{
      "api_version" => @api_version,
      "error" => %{
        "code" => "scheduler_unavailable",
        "message" => "Scheduler could not be reached.",
        "details" => details
      }
    }
  end

  defp start_failed(details) do
    %{
      "api_version" => @api_version,
      "error" => %{
        "code" => "scheduler_start_failed",
        "message" => "Packaged scheduler release failed to start.",
        "details" => details
      }
    }
  end
end
