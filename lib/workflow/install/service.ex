defmodule Workflow.Install.Service do
  @moduledoc false

  import Bitwise, only: [band: 2]

  alias Workflow.Install.Change
  alias Workflow.Install.CodexBinding
  alias Workflow.Install.Command
  alias Workflow.Install.Error
  alias Workflow.Install.MCP
  alias Workflow.PackageVersion

  @label "com.pproenca.codex-loops"
  @unit "codex-loops.service"
  @marker "Managed by Codex Loops"
  @default_host "127.0.0.1"
  @default_port 47_125
  @default_health_timeout 10_000

  defmodule Config do
    @moduledoc false
    @enforce_keys [
      :platform,
      :definition_path,
      :release_command,
      :working_directory,
      :home,
      :binding_path,
      :codex_path,
      :manager_command,
      :host,
      :port,
      :path_env,
      :content
    ]
    defstruct @enforce_keys ++ [:uid, :codex_home]

    @type t :: %__MODULE__{}
  end

  @type state :: :current | :missing | :stopped | :drifted
  @type manager_state :: {:launchd, boolean()} | {:systemd, boolean(), boolean()}
  @type result(value) :: {:ok, value} | {:error, Error.t()}

  @spec config(CodexBinding.t(), keyword()) :: result(Config.t())
  def config(%CodexBinding{} = binding, opts \\ []) do
    with {:ok, platform} <- platform(opts),
         {:ok, home} <- home(opts),
         {:ok, release_command} <- release_command(opts),
         {:ok, binding_path} <- CodexBinding.path(opts),
         {:ok, manager_command} <- manager_command(platform, opts),
         {:ok, uid} <- uid(platform, opts),
         {:ok, path_env} <- service_path_env(binding, opts),
         {:ok, codex_home} <- codex_home(opts) do
      definition_path = definition_path(platform, home, opts)
      working_directory = Keyword.get(opts, :working_directory, Path.join([home, ".codex", "workflows", "runtime"]))
      host = Keyword.get(opts, :host, @default_host)
      port = Keyword.get(opts, :port, @default_port)

      with :ok <- validate_config_path(definition_path, "service definition"),
           :ok <- validate_config_path(working_directory, "service working directory"),
           :ok <-
             validate_render_values(
               Enum.reject(
                 [home, release_command, binding_path, binding.path, manager_command, host, path_env, codex_home],
                 &is_nil/1
               )
             ),
           :ok <- validate_port(port) do
        base = %Config{
          platform: platform,
          definition_path: definition_path,
          release_command: release_command,
          working_directory: working_directory,
          home: home,
          binding_path: binding_path,
          codex_path: binding.path,
          manager_command: manager_command,
          host: host,
          port: port,
          path_env: path_env,
          codex_home: codex_home,
          uid: uid,
          content: ""
        }

        {:ok, %{base | content: render(base)}}
      end
    end
  end

  @spec inspect_state(Config.t(), keyword()) :: result(state())
  def inspect_state(%Config{} = config, opts \\ []) do
    with {:ok, definition} <- read_definition(config),
         :ok <- ensure_owned(definition, config),
         {:ok, manager} <- manager_state(config, opts) do
      health = health_state(config, opts)
      classify(definition, manager, health, config)
    end
  end

  @spec install(Config.t(), keyword()) :: result(Change.t())
  def install(%Config{} = config, opts \\ []) do
    with {:ok, previous_definition} <- snapshot_definition(config),
         :ok <- ensure_owned(previous_shape(previous_definition), config),
         {:ok, previous_manager} <- manager_state(config, opts),
         previous_health = health_state(config, opts),
         :ok <- ensure_installable_endpoint(previous_definition, previous_health, config) do
      case write_definition(config, previous_definition) do
        :ok -> activate_and_verify(config, previous_definition, previous_manager, previous_health, opts)
        {:error, %Error{} = error} -> {:error, error}
      end
    end
  end

  defp activate_and_verify(config, previous_definition, previous_manager, previous_health, opts) do
    with :ok <- activate(config, opts),
         :ok <- wait_healthy(config, opts),
         :ok <- MCP.probe_endpoint(base_url(config), opts),
         :ok <- ensure_manager_current(config, opts) do
      rollback = fn -> restore(config, previous_definition, previous_manager, previous_health, opts, :cas) end
      {:ok, Change.new("service", rollback)}
    else
      {:error, %Error{} = error} ->
        rollback_failed_update(config, previous_definition, previous_manager, previous_health, error, opts)
    end
  end

  defp rollback_failed_update(config, previous_definition, previous_manager, previous_health, error, opts) do
    case restore(config, previous_definition, previous_manager, previous_health, opts, :immediate) do
      :ok ->
        {:error, error}

      {:error, reason} ->
        {:error,
         Error.new(6, "service_rollback_failed", "The failed service update could not be rolled back.",
           details: %{
             "install_error" => Error.to_map(error),
             "rollback_reason" => inspect(reason)
           },
           changed: true
         )}
    end
  end

  @spec start(Config.t(), keyword()) :: result(map())
  def start(%Config{} = config, opts \\ []) do
    with :ok <- require_definition(config),
         :ok <- activate(config, opts),
         :ok <- wait_healthy(config, opts),
         :ok <- MCP.probe_endpoint(base_url(config), opts),
         :ok <- ensure_manager_current(config, opts) do
      {:ok, service_result(config, :running)}
    end
  end

  @spec stop(Config.t(), keyword()) :: result(map())
  def stop(%Config{} = config, opts \\ []) do
    with :ok <- require_definition(config),
         :ok <- deactivate(config, opts, false) do
      {:ok, service_result(config, :stopped)}
    end
  end

  @spec restart(Config.t(), keyword()) :: result(map())
  def restart(%Config{} = config, opts \\ []) do
    with :ok <- require_definition(config),
         :ok <- restart_manager(config, opts),
         :ok <- wait_healthy(config, opts),
         :ok <- MCP.probe_endpoint(base_url(config), opts),
         :ok <- ensure_manager_current(config, opts) do
      {:ok, service_result(config, :running)}
    end
  end

  @spec status(Config.t(), keyword()) :: result(map())
  def status(%Config{} = config, opts \\ []) do
    with {:ok, state} <- inspect_state(config, opts) do
      {:ok, service_result(config, state)}
    end
  end

  @spec health_state(Config.t(), keyword()) ::
          :compatible | :unreachable | {:other_version, term()} | {:incompatible, term()}
  def health_state(%Config{} = config, opts \\ []) do
    case Keyword.get(opts, :health_check) do
      check when is_function(check, 1) -> check.(base_url(config))
      nil -> request_health(config, opts)
    end
  end

  @spec base_url(Config.t()) :: String.t()
  def base_url(%Config{host: host, port: port}) do
    authority_host = if String.contains?(host, ":"), do: "[#{host}]", else: host
    "http://#{authority_host}:#{port}"
  end

  defp classify(:missing, manager, :unreachable, _config) do
    if manager_stopped?(manager), do: {:ok, :missing}, else: {:ok, :drifted}
  end

  defp classify(:missing, _manager, health, config) do
    {:error,
     Error.new(
       4,
       "service_unowned",
       "A scheduler is already using the configured endpoint without the managed service definition.",
       details: %{"server_url" => base_url(config), "health" => inspect(health)}
     )}
  end

  defp classify({:present, content}, manager, :compatible, %Config{content: content}) do
    if manager_current?(manager), do: {:ok, :current}, else: {:ok, :drifted}
  end

  defp classify({:present, content}, manager, :unreachable, %Config{content: content}) do
    if manager_current?(manager), do: {:ok, :drifted}, else: {:ok, :stopped}
  end

  defp classify({:present, _content}, _manager, :compatible, _config), do: {:ok, :drifted}
  defp classify({:present, _content}, _manager, :unreachable, _config), do: {:ok, :drifted}
  defp classify({:present, _content}, _manager, {:other_version, _version}, _config), do: {:ok, :drifted}

  defp classify({:present, content}, _manager, health, %Config{content: content} = config) do
    {:error,
     Error.new(4, "service_endpoint_conflict", "The managed service endpoint is occupied by an incompatible server.",
       details: %{"server_url" => base_url(config), "health" => inspect(health)}
     )}
  end

  defp classify({:present, _content}, _manager, {:incompatible, _detail}, _config), do: {:ok, :drifted}

  defp read_definition(config) do
    case snapshot_definition(config) do
      {:ok, nil} -> {:ok, :missing}
      {:ok, content} -> {:ok, {:present, content}}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp snapshot_definition(config) do
    case File.lstat(config.definition_path) do
      {:error, :enoent} ->
        {:ok, nil}

      {:ok, %File.Stat{type: :regular}} ->
        case File.read(config.definition_path) do
          {:ok, content} -> {:ok, content}
          {:error, reason} -> {:error, file_error("service_read_failed", config.definition_path, reason)}
        end

      {:ok, %File.Stat{type: :symlink}} ->
        {:error,
         Error.new(4, "service_definition_symlink", "The user service definition must not be a symbolic link.",
           details: %{"path" => config.definition_path}
         )}

      {:ok, %File.Stat{type: type}} ->
        {:error,
         Error.new(4, "service_definition_conflict", "The user service definition has an unsupported file type.",
           details: %{"path" => config.definition_path, "type" => to_string(type)}
         )}

      {:error, reason} ->
        {:error, file_error("service_read_failed", config.definition_path, reason)}
    end
  end

  defp previous_shape(nil), do: :missing
  defp previous_shape(content), do: {:present, content}

  defp ensure_installable_endpoint(nil, :unreachable, _config), do: :ok

  defp ensure_installable_endpoint(nil, health, config) do
    {:error,
     Error.new(
       4,
       "service_unowned",
       "A scheduler is already using the configured endpoint without the managed service definition.",
       details: %{"server_url" => base_url(config), "health" => inspect(health)}
     )}
  end

  defp ensure_installable_endpoint(_definition, _health, _config), do: :ok

  defp ensure_owned(:missing, _config), do: :ok
  defp ensure_owned({:present, content}, %Config{content: content}), do: :ok

  defp ensure_owned({:present, content}, config) do
    if owned_definition?(content, config.platform) do
      :ok
    else
      {:error,
       Error.new(4, "service_definition_conflict", "The existing service definition is not owned by Codex Loops.",
         details: %{"path" => config.definition_path}
       )}
    end
  end

  defp write_definition(config, previous_definition) do
    parent = Path.dirname(config.definition_path)
    temporary = config.definition_path <> ".#{System.unique_integer([:positive])}.tmp"

    with :ok <- File.mkdir_p(config.working_directory),
         :ok <- File.mkdir_p(parent),
         :ok <- File.write(temporary, config.content, [:write, :exclusive]),
         :ok <- File.chmod(temporary, 0o600),
         :ok <- require_definition_snapshot(config, previous_definition),
         :ok <- File.rename(temporary, config.definition_path) do
      :ok
    else
      {:error, %Error{} = error} ->
        File.rm(temporary)
        {:error, error}

      {:error, reason} ->
        File.rm(temporary)
        {:error, file_error("service_write_failed", config.definition_path, reason)}
    end
  end

  defp restore(config, previous_definition, previous_manager, previous_health, opts, mode) do
    with {:ok, current_definition} <- snapshot_definition(config),
         {:ok, current_manager} <- manager_state(config, opts) do
      cond do
        current_definition == previous_definition and current_manager == previous_manager ->
          :ok

        current_definition == config.content and (mode == :immediate or manager_current?(current_manager)) ->
          restore_installed_definition(config, previous_definition, previous_manager, previous_health, opts)

        true ->
          {:error, service_changed_error(config, current_manager)}
      end
    end
  end

  defp restore_installed_definition(config, previous_definition, previous_manager, previous_health, opts) do
    _ = deactivate(config, opts, true)

    with :ok <- require_definition_snapshot(config, config.content),
         :ok <- restore_definition(config, previous_definition),
         :ok <- reload_manager(config, opts),
         :ok <- restore_manager_state(config, previous_manager, opts) do
      maybe_restore_health(config, previous_manager, previous_health, opts)
    end
  end

  defp restore_definition(config, nil) do
    with :ok <- require_definition_snapshot(config, config.content) do
      case File.rm(config.definition_path) do
        :ok -> :ok
        {:error, :enoent} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp restore_definition(config, content) do
    path = config.definition_path
    temporary = path <> ".restore.#{System.unique_integer([:positive])}.tmp"

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(temporary, content, [:write, :exclusive]),
         :ok <- File.chmod(temporary, 0o600),
         :ok <- require_definition_snapshot(config, config.content),
         :ok <- File.rename(temporary, path) do
      :ok
    else
      {:error, %Error{} = error} ->
        File.rm(temporary)
        {:error, error}

      {:error, reason} ->
        File.rm(temporary)
        {:error, reason}
    end
  end

  defp maybe_restore_health(config, manager, :compatible, opts) do
    if manager_active?(manager), do: wait_for_health(config, opts, :compatible), else: :ok
  end

  defp maybe_restore_health(config, manager, {:other_version, version}, opts) do
    if manager_active?(manager), do: wait_for_health(config, opts, {:other_version, version}), else: :ok
  end

  defp maybe_restore_health(_config, _manager, _previous_health, _opts), do: :ok

  defp require_definition(config) do
    case snapshot_definition(config) do
      {:ok, content} when is_binary(content) ->
        ensure_owned({:present, content}, config)

      {:ok, nil} ->
        {:error, Error.new(3, "service_not_installed", "The Codex Loops user service is not installed.")}

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp activate(%Config{platform: :darwin} = config, opts) do
    _ = run_manager(config, ["bootout", launch_domain(config), config.definition_path], opts, true)

    with :ok <- run_manager(config, ["bootstrap", launch_domain(config), config.definition_path], opts) do
      run_manager(config, ["kickstart", "-k", launch_service(config)], opts)
    end
  end

  defp activate(%Config{platform: :linux} = config, opts) do
    with :ok <- run_manager(config, ["--user", "daemon-reload"], opts),
         :ok <- run_manager(config, ["--user", "enable", "--now", @unit], opts) do
      run_manager(config, ["--user", "restart", @unit], opts)
    end
  end

  defp restart_manager(%Config{platform: :darwin} = config, opts) do
    run_manager(config, ["kickstart", "-k", launch_service(config)], opts)
  end

  defp restart_manager(%Config{platform: :linux} = config, opts) do
    with :ok <- run_manager(config, ["--user", "daemon-reload"], opts) do
      run_manager(config, ["--user", "restart", @unit], opts)
    end
  end

  defp deactivate(%Config{platform: :darwin} = config, opts, ignore_failure?) do
    run_manager(config, ["bootout", launch_domain(config), config.definition_path], opts, ignore_failure?)
  end

  defp deactivate(%Config{platform: :linux} = config, opts, ignore_failure?) do
    run_manager(config, ["--user", "disable", "--now", @unit], opts, ignore_failure?)
  end

  defp reload_manager(%Config{platform: :darwin}, _opts), do: :ok

  defp reload_manager(%Config{platform: :linux} = config, opts) do
    run_manager(config, ["--user", "daemon-reload"], opts)
  end

  defp manager_state(%Config{platform: :darwin} = config, opts) do
    with {:ok, loaded?} <- manager_flag(config, ["print", launch_service(config)], opts) do
      {:ok, {:launchd, loaded?}}
    end
  end

  defp manager_state(%Config{platform: :linux} = config, opts) do
    with {:ok, enabled?} <- manager_flag(config, ["--user", "is-enabled", @unit], opts),
         {:ok, active?} <- manager_flag(config, ["--user", "is-active", @unit], opts) do
      {:ok, {:systemd, enabled?, active?}}
    end
  end

  defp manager_flag(config, args, opts) do
    runner = Keyword.get(opts, :command_runner, &Command.run/3)
    timeout = Keyword.get(opts, :command_timeout, 5_000)

    case runner.(config.manager_command, args, timeout: timeout, max_output_bytes: 64_000) do
      {:ok, %{status: 0}} ->
        {:ok, true}

      {:ok, %{status: _status}} ->
        {:ok, false}

      {:error, reason} ->
        {:error,
         Error.new(5, "service_manager_query_failed", "The user service manager state could not be read.",
           details: %{"command" => [config.manager_command | args], "reason" => inspect(reason)}
         )}
    end
  end

  defp ensure_manager_current(config, opts) do
    with {:ok, state} <- manager_state(config, opts) do
      if manager_current?(state), do: :ok, else: {:error, manager_state_error(config, state)}
    end
  end

  defp restore_manager_state(%Config{platform: :darwin} = config, {:launchd, true} = expected, opts) do
    with :ok <- activate(config, opts), do: ensure_manager_state(config, expected, opts)
  end

  defp restore_manager_state(%Config{platform: :darwin} = config, {:launchd, false} = expected, opts) do
    with :ok <- deactivate(config, opts, true), do: ensure_manager_state(config, expected, opts)
  end

  defp restore_manager_state(%Config{platform: :linux} = config, {:systemd, enabled?, active?} = expected, opts) do
    with :ok <- restore_systemd_enabled(config, enabled?, opts),
         :ok <- restore_systemd_active(config, active?, opts) do
      ensure_manager_state(config, expected, opts)
    end
  end

  defp restore_systemd_enabled(config, true, opts), do: run_manager(config, ["--user", "enable", @unit], opts)
  defp restore_systemd_enabled(_config, false, _opts), do: :ok
  defp restore_systemd_active(config, true, opts), do: run_manager(config, ["--user", "start", @unit], opts)
  defp restore_systemd_active(_config, false, _opts), do: :ok

  defp ensure_manager_state(config, expected, opts) do
    with {:ok, current} <- manager_state(config, opts) do
      if current == expected, do: :ok, else: {:error, manager_state_error(config, current, expected)}
    end
  end

  defp manager_current?({:launchd, loaded?}), do: loaded?
  defp manager_current?({:systemd, enabled?, active?}), do: enabled? and active?
  defp manager_stopped?({:launchd, loaded?}), do: not loaded?
  defp manager_stopped?({:systemd, enabled?, active?}), do: not enabled? and not active?
  defp manager_active?({:launchd, loaded?}), do: loaded?
  defp manager_active?({:systemd, _enabled?, active?}), do: active?

  defp manager_state_error(config, current, expected \\ :current) do
    Error.new(6, "service_manager_state_invalid", "The user service manager did not reach the required state.",
      details: %{
        "definition" => config.definition_path,
        "current" => inspect(current),
        "expected" => inspect(expected)
      }
    )
  end

  defp run_manager(config, args, opts, ignore_failure? \\ false) do
    runner = Keyword.get(opts, :command_runner, &Command.run/3)
    timeout = Keyword.get(opts, :command_timeout, 5_000)

    case runner.(config.manager_command, args, timeout: timeout) do
      {:ok, %{status: 0}} ->
        :ok

      {:ok, %{status: _status}} when ignore_failure? ->
        :ok

      {:error, _reason} when ignore_failure? ->
        :ok

      {:ok, %{status: status, output: output}} ->
        {:error,
         Error.new(5, "service_command_failed", "The user service manager command failed.",
           details: %{"command" => [config.manager_command | args], "status" => status, "output" => String.trim(output)}
         )}

      {:error, reason} ->
        {:error,
         Error.new(5, "service_command_failed", "The user service manager command failed.",
           details: %{"command" => [config.manager_command | args], "reason" => inspect(reason)}
         )}
    end
  end

  defp wait_healthy(config, opts) do
    wait_for_health(config, opts, :compatible)
  end

  defp wait_for_health(config, opts, expected_health) do
    timeout = Keyword.get(opts, :health_timeout, @default_health_timeout)
    interval = Keyword.get(opts, :health_interval, 100)

    wait_for_health(
      config,
      opts,
      expected_health,
      System.monotonic_time(:millisecond) + timeout,
      interval
    )
  end

  defp wait_for_health(config, opts, expected_health, deadline, interval) do
    case health_state(config, opts) do
      ^expected_health ->
        :ok

      health ->
        remaining = deadline - System.monotonic_time(:millisecond)

        if remaining <= 0 do
          {:error,
           Error.new(6, "service_health_failed", "The managed scheduler did not become healthy before the deadline.",
             details: %{"server_url" => base_url(config), "health" => inspect(health)}
           )}
        else
          Process.sleep(min(interval, remaining))
          wait_for_health(config, opts, expected_health, deadline, interval)
        end
    end
  end

  defp request_health(config, opts) do
    request_timeout = Keyword.get(opts, :health_request_timeout, 500)
    _ = Application.ensure_all_started(:inets)
    url = String.to_charlist(base_url(config) <> "/api/health")

    case :httpc.request(:get, {url, []}, [timeout: request_timeout, connect_timeout: request_timeout],
           body_format: :binary
         ) do
      {:ok, {{_http_version, 200, _reason}, _headers, body}} -> decode_health(body)
      {:ok, {{_http_version, status, _reason}, _headers, body}} -> {:incompatible, %{"status" => status, "body" => body}}
      {:error, _reason} -> :unreachable
    end
  end

  defp decode_health(body) do
    case Jason.decode(body) do
      {:ok,
       %{
         "api_version" => "scheduler.v1",
         "data" => %{"status" => "ok", "version" => version}
       }} ->
        if version == PackageVersion.version(), do: :compatible, else: {:other_version, version}

      {:ok, payload} ->
        {:incompatible, payload}

      {:error, error} ->
        {:incompatible, Exception.message(error)}
    end
  end

  defp render(%Config{platform: :darwin} = config) do
    env = environment(config)

    environment_xml =
      Enum.map_join(env, "\n", fn {key, value} ->
        "      <key>#{xml(key)}</key>\n      <string>#{xml(value)}</string>"
      end)

    """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <!-- #{@marker} -->
    <plist version="1.0">
    <dict>
      <key>Label</key>
      <string>#{@label}</string>
      <key>ProgramArguments</key>
      <array>
        <string>#{xml(config.release_command)}</string>
        <string>foreground</string>
      </array>
      <key>WorkingDirectory</key>
      <string>#{xml(config.working_directory)}</string>
      <key>EnvironmentVariables</key>
      <dict>
    #{environment_xml}
      </dict>
      <key>RunAtLoad</key>
      <true/>
      <key>KeepAlive</key>
      <dict>
        <key>SuccessfulExit</key>
        <false/>
      </dict>
      <key>StandardOutPath</key>
      <string>#{xml(Path.join(config.working_directory, "scheduler.log"))}</string>
      <key>StandardErrorPath</key>
      <string>#{xml(Path.join(config.working_directory, "scheduler.log"))}</string>
    </dict>
    </plist>
    """
  end

  defp render(%Config{platform: :linux} = config) do
    environment =
      Enum.map_join(environment(config), "\n", fn {key, value} -> "Environment=#{systemd_quote("#{key}=#{value}")}" end)

    """
    # #{@marker}
    [Unit]
    Description=Codex Loops scheduler
    After=network.target

    [Service]
    Type=simple
    WorkingDirectory=#{systemd_quote(config.working_directory)}
    ExecStart=#{systemd_exec_quote(config.release_command)} foreground
    Restart=on-failure
    RestartSec=1
    #{environment}

    [Install]
    WantedBy=default.target
    """
  end

  defp environment(config) do
    env =
      [
        {"HOME", config.home},
        {"PATH", config.path_env},
        {"RELEASE_DISTRIBUTION", "none"},
        {"CODEX_LOOPS_SERVER", "1"},
        {"CODEX_LOOPS_HOST", config.host},
        {"CODEX_LOOPS_PORT", Integer.to_string(config.port)},
        {"CODEX_LOOPS_BINDING_PATH", config.binding_path},
        {"CODEX_LOOPS_CODEX_BIN", config.codex_path}
      ]

    if config.codex_home, do: env ++ [{"CODEX_HOME", config.codex_home}], else: env
  end

  defp xml(value) do
    value
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&apos;")
  end

  defp systemd_quote(value) do
    escaped =
      value
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")
      |> String.replace("%", "%%")

    "\"#{escaped}\""
  end

  defp systemd_exec_quote(value), do: value |> String.replace("$", "$$") |> systemd_quote()

  defp owned_definition?(content, :linux), do: String.starts_with?(content, "# #{@marker}\n")

  defp owned_definition?(content, :darwin) do
    case String.split(content, "\n", parts: 4) do
      [~s(<?xml version="1.0" encoding="UTF-8"?>), _doctype, "<!-- #{@marker} -->", _rest] -> true
      _other -> false
    end
  end

  defp require_definition_snapshot(config, expected) do
    with {:ok, current} <- snapshot_definition(config) do
      if current == expected, do: :ok, else: {:error, definition_changed_error(config)}
    end
  end

  defp definition_changed_error(config) do
    Error.new(4, "service_definition_changed", "The managed service definition changed during installation.",
      details: %{"path" => config.definition_path}
    )
  end

  defp service_changed_error(config, manager) do
    Error.new(
      4,
      "service_definition_changed",
      "The managed service definition or manager state changed during installation.",
      details: %{"path" => config.definition_path, "manager" => inspect(manager)}
    )
  end

  defp validate_config_path(path, label) when is_binary(path) do
    if Path.type(path) == :absolute do
      validate_render_values([path])
    else
      {:error, Error.new(3, "service_path_invalid", "The #{label} path must be absolute.", details: %{"path" => path})}
    end
  end

  defp validate_config_path(path, label) do
    {:error, Error.new(3, "service_path_invalid", "The #{label} path must be absolute.", details: %{"path" => path})}
  end

  defp validate_render_values(values) do
    if Enum.all?(values, &safe_render_value?/1) do
      :ok
    else
      {:error, Error.new(3, "service_value_invalid", "Service configuration values must not contain control characters.")}
    end
  end

  defp safe_render_value?(value) when is_binary(value) do
    String.valid?(value) and
      value
      |> String.to_charlist()
      |> Enum.all?(fn codepoint -> codepoint >= 0x20 and codepoint != 0x7F end)
  end

  defp safe_render_value?(_value), do: false

  defp service_path_env(binding, opts) do
    value = if Keyword.has_key?(opts, :path_env), do: Keyword.get(opts, :path_env), else: System.get_env("PATH")

    case value do
      path when is_binary(path) and path != "" ->
        segments = String.split(path, ":", trim: false)
        codex_directory = Path.dirname(binding.path)

        if not String.contains?(codex_directory, ":") and
             Enum.all?(segments, &(Path.type(&1) == :absolute and safe_render_value?(&1))) do
          segments = if codex_directory in segments, do: segments, else: [codex_directory | segments]
          {:ok, Enum.join(segments, ":")}
        else
          {:error,
           Error.new(
             3,
             "service_path_env_invalid",
             "PATH must contain only non-empty absolute paths with no control characters."
           )}
        end

      _missing ->
        {:error,
         Error.new(3, "service_path_env_invalid", "A non-empty PATH is required for the managed scheduler service.")}
    end
  end

  defp codex_home(opts) do
    value = if Keyword.has_key?(opts, :codex_home), do: Keyword.get(opts, :codex_home), else: System.get_env("CODEX_HOME")

    case value do
      nil ->
        {:ok, nil}

      path when is_binary(path) and path != "" ->
        if Path.type(path) == :absolute and safe_render_value?(path) do
          {:ok, path}
        else
          {:error, Error.new(3, "codex_home_invalid", "CODEX_HOME must be an absolute path with no control characters.")}
        end

      _invalid ->
        {:error, Error.new(3, "codex_home_invalid", "CODEX_HOME must be an absolute path with no control characters.")}
    end
  end

  defp validate_port(port) when is_integer(port) and port in 1..65_535, do: :ok

  defp validate_port(port) do
    {:error,
     Error.new(3, "service_port_invalid", "The managed scheduler port must be an integer from 1 to 65535.",
       details: %{"port" => inspect(port)}
     )}
  end

  defp platform(opts) do
    case Keyword.get(opts, :platform) || :os.type() do
      :darwin ->
        {:ok, :darwin}

      :linux ->
        {:ok, :linux}

      {:unix, :darwin} ->
        {:ok, :darwin}

      {:unix, :linux} ->
        {:ok, :linux}

      platform ->
        {:error,
         Error.new(3, "service_manager_unsupported", "Codex Loops requires launchd or systemd --user.",
           details: %{"platform" => inspect(platform)}
         )}
    end
  end

  defp home(opts) do
    case Keyword.get(opts, :home) || System.get_env("HOME") do
      home when is_binary(home) and home != "" ->
        if Path.type(home) == :absolute do
          {:ok, home}
        else
          {:error, Error.new(3, "home_unavailable", "A user home directory is required.")}
        end

      _ ->
        {:error, Error.new(3, "home_unavailable", "A user home directory is required.")}
    end
  end

  defp release_command(opts) do
    path = Keyword.get(opts, :release_command) || System.get_env("CODEX_LOOPS_RELEASE_COMMAND")

    with path when is_binary(path) and path != "" <- path,
         :absolute <- Path.type(path),
         {:ok, %File.Stat{type: :regular, mode: mode}} <- File.stat(path),
         true <- band(mode, 0o111) != 0 do
      {:ok, path}
    else
      _ ->
        {:error,
         Error.new(3, "release_command_invalid", "The packaged foreground release command is missing or not executable.",
           details: %{"path" => path}
         )}
    end
  end

  defp manager_command(:darwin, opts), do: configured_manager(opts, "/bin/launchctl", "launchctl")
  defp manager_command(:linux, opts), do: configured_manager(opts, System.find_executable("systemctl"), "systemctl")

  defp configured_manager(opts, default, name) do
    case Keyword.get(opts, :manager_command, default) do
      command when is_binary(command) and command != "" -> {:ok, command}
      _ -> {:error, Error.new(3, "service_manager_unavailable", "The #{name} user service manager is unavailable.")}
    end
  end

  defp uid(:linux, _opts), do: {:ok, nil}

  defp uid(:darwin, opts) do
    case Keyword.get(opts, :uid) || System.get_env("UID") do
      uid when is_integer(uid) and uid >= 0 -> {:ok, uid}
      uid when is_binary(uid) -> parse_uid(uid)
      nil -> probe_uid(opts)
    end
  end

  defp probe_uid(opts) do
    runner = Keyword.get(opts, :command_runner, &Command.run/3)

    case runner.("/usr/bin/id", ["-u"], timeout: 1_000, max_output_bytes: 128) do
      {:ok, %{status: 0, output: output}} -> parse_uid(output)
      _ -> {:error, Error.new(3, "user_identity_unavailable", "The launchd user domain could not be resolved.")}
    end
  end

  defp parse_uid(raw) do
    case raw |> String.trim() |> Integer.parse() do
      {uid, ""} when uid >= 0 -> {:ok, uid}
      _ -> {:error, Error.new(3, "user_identity_unavailable", "The launchd user domain could not be resolved.")}
    end
  end

  defp definition_path(:darwin, home, opts),
    do: Keyword.get(opts, :service_path, Path.join([home, "Library", "LaunchAgents", @label <> ".plist"]))

  defp definition_path(:linux, home, opts) do
    config_home = Keyword.get(opts, :xdg_config_home) || System.get_env("XDG_CONFIG_HOME") || Path.join(home, ".config")
    Keyword.get(opts, :service_path, Path.join([config_home, "systemd", "user", @unit]))
  end

  defp launch_domain(config), do: "gui/#{config.uid}"
  defp launch_service(config), do: launch_domain(config) <> "/" <> @label

  defp service_result(config, state) do
    %{
      "state" => to_string(state),
      "platform" => to_string(config.platform),
      "definition" => config.definition_path,
      "server_url" => base_url(config)
    }
  end

  defp file_error(code, path, reason) do
    Error.new(6, code, "The Codex Loops user service definition could not be updated.",
      details: %{"path" => path, "reason" => inspect(reason)}
    )
  end
end
