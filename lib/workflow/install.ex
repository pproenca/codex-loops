defmodule Workflow.Install do
  @moduledoc """
  Reconciles the user-local Codex binding, scheduler service, skill, and MCP URL.

  The archive installer activates an immutable bundle first, then invokes this
  module once. Every mutating action returns a compensating rollback, so a later
  failure restores the previously active user integration.
  """

  alias Workflow.Install.Change
  alias Workflow.Install.CodexBinding
  alias Workflow.Install.Error
  alias Workflow.Install.Lock
  alias Workflow.Install.MCP
  alias Workflow.Install.Service
  alias Workflow.Install.Skill
  alias Workflow.PackageVersion

  @type mode :: :install | :check | :dry_run
  @type result(value) :: {:ok, value} | {:error, Error.t()}

  @spec run(mode(), keyword()) :: result(map())
  def run(mode, opts \\ []) when mode in [:install, :check, :dry_run] do
    case mode do
      :install -> with_install_lock(opts, fn -> reconcile(mode, opts) end)
      _ -> reconcile(mode, opts)
    end
  end

  @spec service_config(keyword()) :: result(Service.Config.t())
  def service_config(opts \\ []) do
    binding_result =
      if Keyword.get(opts, :verify_binding, true) do
        CodexBinding.load_and_verify(opts)
      else
        CodexBinding.read(opts)
      end

    with {:ok, binding} <- binding_result do
      Service.config(binding, opts)
    end
  end

  @spec doctor(keyword()) :: result(map())
  def doctor(opts \\ []) do
    with {:ok, binding} <- CodexBinding.load_and_verify(opts),
         {:ok, service} <- Service.config(binding, opts),
         {:ok, service_status} <- Service.status(service, opts),
         :ok <- MCP.probe_endpoint(Service.base_url(service), opts),
         {:ok, skill} <- Skill.config(opts),
         {:ok, skill_state} <- Skill.inspect_state(skill),
         {:ok, mcp_state} <- MCP.inspect_state(binding, opts) do
      {:ok,
       %{
         "binding" => binding_map(binding),
         "service" => service_status,
         "skill" => %{"path" => skill.destination, "state" => to_string(skill_state)},
         "mcp" => %{"name" => MCP.name(), "url" => MCP.url(), "state" => state_name(mcp_state)}
       }}
    end
  end

  defp reconcile(mode, opts) do
    with {:ok, context} <- context(opts) do
      actions = plan(context)
      finish(mode, context, actions, opts)
    end
  end

  defp context(opts) do
    with {:ok, binding} <- select_binding(opts),
         {:ok, stored_binding} <- CodexBinding.read_optional(opts),
         {:ok, service} <- Service.config(binding, opts),
         {:ok, service_state} <- Service.inspect_state(service, opts),
         :ok <- probe_current_service(service, service_state, opts),
         {:ok, skill} <- Skill.config(opts),
         {:ok, skill_state} <- Skill.inspect_state(skill),
         {:ok, mcp_state} <- MCP.inspect_state(binding, opts) do
      {:ok,
       %{
         binding: binding,
         binding_state: if(stored_binding == binding, do: :current, else: :drifted),
         service: service,
         service_state: service_state,
         skill: skill,
         skill_state: skill_state,
         mcp_state: mcp_state
       }}
    end
  end

  defp select_binding(opts) do
    case Keyword.get(opts, :codex) do
      nil -> select_implicit_binding(opts)
      path -> CodexBinding.probe(path, opts)
    end
  end

  defp select_implicit_binding(opts) do
    case CodexBinding.read_optional(opts) do
      {:ok, %CodexBinding{path: path}} ->
        CodexBinding.probe(path, opts)

      {:ok, nil} ->
        case find_codex(opts) do
          nil ->
            {:error,
             Error.new(3, "codex_binding_required", "Codex CLI was not found; pass --codex with its absolute path.")}

          path ->
            CodexBinding.probe(path, opts)
        end

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp find_codex(opts) do
    case Keyword.get(opts, :find_executable, &System.find_executable/1).("codex") do
      nil -> nil
      path -> Path.expand(path)
    end
  end

  defp plan(context) do
    []
    |> add_action(context.binding_state != :current, {:binding, context.binding})
    |> add_action(context.service_state != :current or context.binding_state != :current, {:service, context.service})
    |> add_action(context.skill_state != :current, {:skill, context.skill})
    |> add_action(context.mcp_state != :current, {:mcp, context.binding, context.mcp_state})
  end

  defp add_action(actions, true, action), do: actions ++ [action]
  defp add_action(actions, false, _action), do: actions

  defp finish(:check, context, [], opts) do
    with :ok <- final_gate(context, opts), do: {:ok, output(:check, context, [], false)}
  end

  defp finish(:check, _context, actions, _opts) do
    {:error,
     Error.new(1, "state_missing", "Codex Loops is not fully installed.", details: %{"plan" => action_names(actions)})}
  end

  defp finish(:dry_run, context, actions, _opts), do: {:ok, output(:dry_run, context, actions, false)}

  defp finish(:install, context, actions, opts) do
    case execute(actions, opts, []) do
      {:ok, changes} ->
        case final_gate(context, opts) do
          :ok ->
            case commit(changes) do
              :ok ->
                {:ok, output(:install, context, actions, actions != [])}

              {:error, failures} ->
                result = output(:install, context, actions, actions != [])

                {:ok, Map.put(result, "warnings", [%{"code" => "install_cleanup_failed", "failures" => failures}])}
            end

          {:error, %Error{} = error} ->
            rollback_failure(error, Enum.reverse(changes))
        end

      {:error, %Error{} = error, changes} ->
        rollback_failure(error, changes)
    end
  end

  defp execute(actions, opts, changes) do
    case Enum.reduce_while(actions, changes, fn action, changes ->
           case execute_action(action, opts) do
             {:ok, %Change{} = change} -> {:cont, [change | changes]}
             {:error, %Error{} = error} -> {:halt, {:error, error, changes}}
           end
         end) do
      {:error, %Error{} = error, changes} -> {:error, error, changes}
      changes -> {:ok, Enum.reverse(changes)}
    end
  end

  defp execute_action({:binding, binding}, opts) do
    with {:ok, previous} <- CodexBinding.snapshot(opts),
         {:ok, installed} <- CodexBinding.serialized(binding),
         :ok <- CodexBinding.persist(binding, opts) do
      rollback = fn -> CodexBinding.restore_if_current(previous, installed, opts) end
      {:ok, Change.new("binding", rollback)}
    end
  end

  defp execute_action({:service, service}, opts), do: Service.install(service, opts)
  defp execute_action({:skill, skill}, opts), do: Skill.install(skill, opts)
  defp execute_action({:mcp, binding, state}, opts), do: MCP.install(binding, state, opts)

  defp rollback_failure(error, changes) do
    failures = rollback(changes)

    case failures do
      [] ->
        {:error, Error.changed(error, changes != [] or error.changed)}

      failures ->
        {:error,
         Error.new(
           6,
           "install_rollback_failed",
           "Codex Loops installation failed and prior state could not be fully restored.",
           details: %{
             "install_error" => Error.to_map(error),
             "rollback_failures" => failures
           },
           changed: true
         )}
    end
  end

  defp rollback(changes) do
    changes
    |> Enum.sort_by(fn change -> if change.name == "binding", do: 0, else: 1 end)
    |> Enum.flat_map(fn change ->
      case change.rollback.() do
        :ok -> []
        {:error, reason} -> [%{"action" => change.name, "reason" => rollback_reason(reason)}]
      end
    end)
  end

  defp commit(changes) do
    failures =
      Enum.flat_map(changes, fn change ->
        case change.commit.() do
          :ok -> []
          {:error, reason} -> [%{"action" => change.name, "reason" => inspect(reason)}]
        end
      end)

    if failures == [], do: :ok, else: {:error, failures}
  end

  defp output(mode, context, actions, changed) do
    %{
      "changed" => changed,
      "mode" => mode_name(mode),
      "version" => PackageVersion.version(),
      "plan" => action_names(actions),
      "binding" => binding_map(context.binding),
      "service" => %{
        "definition" => context.service.definition_path,
        "server_url" => Service.base_url(context.service),
        "state" => reported_state(mode, context.service_state)
      },
      "skill" => %{"path" => context.skill.destination, "state" => reported_state(mode, context.skill_state)},
      "mcp" => %{"name" => MCP.name(), "url" => MCP.url(), "state" => reported_state(mode, context.mcp_state)},
      "next_steps" => ["Restart Codex, then ask: Use the codex-loops skill."]
    }
  end

  defp action_names(actions), do: Enum.map(actions, &action_name/1)
  defp action_name({:binding, _binding}), do: "bind_codex"
  defp action_name({:service, _service}), do: "install_service"
  defp action_name({:skill, _skill}), do: "install_skill"
  defp action_name({:mcp, _binding, :missing}), do: "add_mcp"
  defp action_name({:mcp, _binding, {:replace, _registration}}), do: "replace_mcp"

  defp mode_name(:dry_run), do: "dry_run"
  defp mode_name(mode), do: to_string(mode)

  defp state_name({:replace, _registration}), do: "replace"
  defp state_name(state), do: to_string(state)

  defp reported_state(:install, _state), do: "current"
  defp reported_state(_mode, state), do: state_name(state)

  defp probe_current_service(service, :current, opts), do: MCP.probe_endpoint(Service.base_url(service), opts)
  defp probe_current_service(_service, _state, _opts), do: :ok

  defp final_gate(context, opts) do
    with {:ok, persisted} <- CodexBinding.read(opts),
         :ok <- require_expected_binding(persisted, context.binding),
         {:ok, _binding} <- CodexBinding.verify(context.binding, opts),
         {:ok, service_state} <- Service.inspect_state(context.service, opts),
         :ok <- require_current_surface("service", service_state),
         {:ok, skill_state} <- Skill.inspect_state(context.skill),
         :ok <- require_current_surface("skill", skill_state),
         {:ok, mcp_state} <- MCP.inspect_state(persisted, opts),
         :ok <- require_current_surface("mcp", mcp_state) do
      MCP.probe_endpoint(Service.base_url(context.service), opts)
    end
  end

  defp require_current_surface(_surface, :current), do: :ok

  defp require_current_surface(surface, state) do
    {:error,
     Error.new(4, "install_final_state_changed", "An installed surface changed before final verification.",
       details: %{"surface" => surface, "state" => state_name(state)}
     )}
  end

  defp require_expected_binding(expected, expected), do: :ok

  defp require_expected_binding(persisted, expected) do
    {:error,
     Error.new(4, "codex_binding_changed", "The persisted Codex binding changed during installation.",
       details: %{
         "expected" => binding_map(expected),
         "persisted" => binding_map(persisted)
       }
     )}
  end

  defp binding_map(binding), do: %{"path" => binding.path, "version" => binding.version}

  defp rollback_reason(%Error{} = error), do: Error.to_map(error)
  defp rollback_reason(reason), do: inspect(reason)

  defp with_install_lock(opts, fun) do
    with {:ok, lock_path} <- lock_path(opts), do: Lock.with_lock(lock_path, opts, fun)
  end

  defp lock_path(opts) do
    case Keyword.get(opts, :install_lock_path) do
      path when is_binary(path) and path != "" ->
        if Path.type(path) == :absolute,
          do: {:ok, path},
          else: {:error, Error.new(2, "install_lock_invalid", "The installation lock path must be absolute.")}

      nil ->
        with {:ok, binding_path} <- CodexBinding.path(opts) do
          {:ok, Path.join(Path.dirname(binding_path), "install.lock")}
        end
    end
  end
end
