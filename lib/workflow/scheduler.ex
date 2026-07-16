defmodule Workflow.Scheduler do
  @moduledoc """
  Product API boundary for scheduler clients.

  Phoenix controllers call this context instead of reaching into journal or runtime
  internals. Expected API failures return tagged tuples with typed error data;
  unexpected process failures are left to crash under supervision.
  """

  alias Workflow.Event
  alias Workflow.Event.Payload
  alias Workflow.Journal
  alias Workflow.PackageVersion
  alias Workflow.Provider.Codex
  alias Workflow.Provider.Mock
  alias Workflow.Run
  alias Workflow.Run.Input
  alias Workflow.Run.Options, as: RunOptions
  alias Workflow.Scheduler.Error
  alias Workflow.Scheduler.Health
  alias Workflow.Scheduler.RunEventsProjection
  alias Workflow.Scheduler.RunProjection
  alias Workflow.Scheduler.RunStart
  alias Workflow.Scheduler.Snapshot
  alias Workflow.Scheduler.Validation
  alias Workflow.Scheduler.Workspace
  alias Workflow.Script
  alias Workflow.Status

  @app :codex_loops
  @max_run_id_bytes 128
  @supported_providers ["mock", "codex"]

  @spec health() :: {:ok, Health.t()} | {:error, Error.t()}
  def health do
    checks = %{
      otp_app: available?(application_started?(@app)),
      execution: available?(Workflow.Execution.available?()),
      journal: available?(process_alive?(Journal)),
      pubsub: available?(process_alive?(Workflow.PubSub))
    }

    if Enum.all?(checks, fn {_dependency, status} -> status == :available end) do
      {:ok, %Health{status: :ok, version: PackageVersion.version(), checks: checks}}
    else
      {:error, Error.unavailable(checks)}
    end
  end

  @spec start_run(map()) :: {:ok, RunStart.t()} | {:error, Error.t()}
  def start_run(params) when is_map(params) do
    with {:ok, path} <- run_script_path(params),
         {:ok, run_id} <- run_id(params),
         {:ok, provider} <- run_provider(params),
         {:ok, budget} <- run_budget(params),
         {:ok, args} <- run_args(params),
         {:ok, requested_workspace_root} <- run_workspace_root(params),
         {:ok, workspace} <- Workspace.resolve(path, requested_workspace_root),
         {:ok, tree} <- Script.load_tree(workspace.script_path) do
      options = %RunOptions{
        run_id: run_id,
        provider: provider_with_workspace(provider, workspace.workspace_root),
        budget: budget,
        args: args,
        script_path: workspace.script_path,
        workspace_root: workspace.workspace_root
      }

      start_result(Run.start(tree, options), run_id)
    else
      {:error, %Workflow.Script.Error{} = error} -> {:error, Error.workflow_validation(error)}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  def start_run(_params), do: {:error, Error.missing_script_path()}

  @spec resume_run(String.t(), map()) :: {:ok, RunStart.t()} | {:error, Error.t()}
  def resume_run(run_id, params \\ %{})

  def resume_run(run_id, params) when is_binary(run_id) and is_map(params) do
    with {:ok, run_id} <- route_safe_run_id(run_id),
         :ok <- ensure_run_exists(run_id),
         :ok <- ensure_resume_args_absent(params),
         {:ok, provider} <- run_provider(params),
         {:ok, path} <- resume_script_path(run_id, params),
         {:ok, requested_workspace_root} <- resume_workspace_root(run_id, params),
         {:ok, workspace} <- Workspace.resolve(path, requested_workspace_root),
         {:ok, tree} <- Script.load_tree(workspace.script_path) do
      options = %RunOptions{
        run_id: run_id,
        provider: provider_with_workspace(provider, workspace.workspace_root),
        budget: nil,
        script_path: workspace.script_path,
        workspace_root: workspace.workspace_root
      }

      start_result(Run.start(tree, options), run_id)
    else
      {:error, %Workflow.Script.Error{} = error} -> {:error, Error.workflow_validation(error)}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  def resume_run(_run_id, _params), do: {:error, Error.invalid_run_id()}

  @spec get_run(String.t()) :: {:ok, RunProjection.t()} | {:error, Error.t()}
  def get_run(run_id) do
    with {:ok, run_id} <- route_safe_run_id(run_id) do
      if Journal.run_exists?(run_id) do
        {:ok, run_projection(run_id)}
      else
        {:error, Error.run_not_found(run_id)}
      end
    end
  end

  @doc """
  Returns the complete scheduler-owned read model for one render.

  The journal is folded once, then both the workflow status body and lifecycle
  projection are derived from those events plus the current runtime lease fact.
  """
  @spec get_run_snapshot(String.t()) :: {:ok, Snapshot.t()} | {:error, Error.t()}
  def get_run_snapshot(run_id) do
    with {:ok, run_id} <- route_safe_run_id(run_id) do
      if Journal.run_exists?(run_id) do
        {:ok, run_snapshot(run_id)}
      else
        {:error, Error.run_not_found(run_id)}
      end
    end
  end

  @spec get_run_events(String.t()) :: {:ok, RunEventsProjection.t()} | {:error, Error.t()}
  def get_run_events(run_id) do
    with {:ok, run_id} <- route_safe_run_id(run_id) do
      if Journal.run_exists?(run_id) do
        {:ok, RunEventsProjection.from_events(run_id, Journal.fold(run_id))}
      else
        {:error, Error.run_not_found(run_id)}
      end
    end
  end

  @spec validate_workflow(map()) :: {:ok, Validation.t()} | {:error, Error.t()}
  def validate_workflow(params) when is_map(params) do
    with {:ok, path} <- run_script_path(params),
         {:ok, requested_workspace_root} <- run_workspace_root(params),
         {:ok, workspace} <- Workspace.resolve(path, requested_workspace_root),
         {:ok, tree} <- Script.load_tree(workspace.script_path),
         :ok <- validate_supplied_args(tree, params) do
      {:ok, Validation.from_tree(tree, workspace.script_path, arguments_validated: supplied_args?(params))}
    else
      {:error, %Workflow.Script.Error{} = error} -> {:error, Error.workflow_validation(error)}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  def validate_workflow(_params), do: {:error, Error.missing_script_path()}

  defp run_script_path(params) do
    case explicit_script_path(params) do
      {:ok, path} -> {:ok, path}
      :missing -> {:error, Error.missing_script_path()}
      {:error, error} -> {:error, error}
    end
  end

  defp explicit_script_path(params) do
    case fetch_param(params, :script_path, "script_path") do
      {:ok, path} when is_binary(path) and byte_size(path) > 0 -> {:ok, path}
      :missing -> explicit_script_alias(params)
      {:ok, _invalid} -> {:error, Error.missing_script_path()}
    end
  end

  defp explicit_script_alias(params) do
    case fetch_param(params, :script, "script") do
      {:ok, path} when is_binary(path) and byte_size(path) > 0 -> {:ok, path}
      :missing -> :missing
      {:ok, _invalid} -> {:error, Error.missing_script_path()}
    end
  end

  defp resume_script_path(run_id, params) do
    case explicit_script_path(params) do
      {:ok, path} -> {:ok, path}
      :missing -> journaled_script_path(run_id)
      {:error, error} -> {:error, error}
    end
  end

  defp journaled_script_path(run_id) do
    case Enum.find(Journal.fold(run_id), fn
           %Event{payload: %Payload.RunStarted{}} -> true
           %Event{} -> false
         end) do
      %Event{payload: %Payload.RunStarted{script_path: path}}
      when is_binary(path) and byte_size(path) > 0 ->
        {:ok, path}

      _missing_or_unrecorded ->
        {:error, Error.missing_script_path()}
    end
  end

  defp run_workspace_root(params) do
    case explicit_workspace_root(params) do
      {:ok, root} -> {:ok, root}
      :missing -> {:ok, nil}
      {:error, error} -> {:error, error}
    end
  end

  defp resume_workspace_root(run_id, params) do
    case explicit_workspace_root(params) do
      {:ok, root} -> {:ok, root}
      :missing -> {:ok, journaled_workspace_root(run_id)}
      {:error, error} -> {:error, error}
    end
  end

  defp explicit_workspace_root(params) do
    case fetch_param(params, :workspace_root, "workspace_root") do
      {:ok, root} when is_binary(root) and byte_size(root) > 0 -> {:ok, root}
      :missing -> :missing
      {:ok, invalid} -> {:error, Error.invalid_workspace_root(invalid, :invalid_value)}
    end
  end

  defp journaled_workspace_root(run_id) do
    case Enum.find(Journal.fold(run_id), fn
           %Event{payload: %Payload.RunStarted{}} -> true
           %Event{} -> false
         end) do
      %Event{payload: %Payload.RunStarted{workspace_root: root}}
      when is_binary(root) and byte_size(root) > 0 ->
        root

      _missing_or_legacy ->
        nil
    end
  end

  defp run_id(params) do
    case fetch_param(params, :run_id, "run_id") do
      :missing -> {:ok, RunOptions.generate_run_id()}
      {:ok, id} -> route_safe_run_id(id)
    end
  end

  defp route_safe_run_id(id) when is_binary(id) do
    if byte_size(id) in 1..@max_run_id_bytes and String.valid?(id) and
         Regex.match?(~r/^[A-Za-z0-9][A-Za-z0-9_.:-]*$/, id) do
      {:ok, :binary.copy(id)}
    else
      {:error, Error.invalid_run_id()}
    end
  end

  defp route_safe_run_id(_id), do: {:error, Error.invalid_run_id()}

  defp ensure_run_exists(run_id) do
    if Journal.run_exists?(run_id) do
      :ok
    else
      {:error, Error.run_not_found(run_id)}
    end
  end

  defp run_projection(run_id) do
    %Snapshot{run_projection: run_projection} = run_snapshot(run_id)
    run_projection
  end

  defp run_snapshot(run_id) do
    events = Journal.fold(run_id)
    status = Status.fold(events, run_id)

    run_projection =
      RunProjection.from_status(status,
        events: events,
        running?: run_running?(run_id)
      )

    %Snapshot{status: status, run_projection: run_projection}
  end

  defp run_running?(run_id) do
    case Registry.lookup(Workflow.Run.Registry, run_id) do
      [] -> false
      [{_pid, _value} | _rest] -> true
    end
  end

  defp run_provider(params) do
    case fetch_param(params, :provider, "provider") do
      :missing -> {:ok, {Mock, []}}
      {:ok, provider} when provider in ["mock", :mock] -> {:ok, {Mock, []}}
      {:ok, provider} when provider in ["codex", :codex] -> {:ok, {Codex, []}}
      {:ok, _unsupported} -> {:error, Error.invalid_provider(@supported_providers)}
    end
  end

  defp provider_with_workspace({Codex, opts}, workspace_root) do
    opts =
      opts
      |> Keyword.put(:workspace_root, workspace_root)
      |> Keyword.put(:cwd, workspace_root)

    {Codex, opts}
  end

  defp provider_with_workspace(provider, _workspace_root), do: provider

  defp run_budget(params) do
    case fetch_param(params, :budget, "budget") do
      :missing -> {:ok, nil}
      {:ok, budget} when is_integer(budget) and budget >= 0 -> {:ok, budget}
      {:ok, _invalid} -> {:error, Error.invalid_budget()}
    end
  end

  defp run_args(params) do
    case fetch_param(params, :args, "args") do
      :missing -> {:ok, :not_provided}
      {:ok, args} -> {:ok, args}
    end
  end

  defp validate_supplied_args(tree, params) do
    case run_args(params) do
      {:ok, :not_provided} ->
        :ok

      {:ok, args} ->
        with {:ok, args} <- Input.normalize(args),
             :ok <- Input.validate(tree.input_schema, args) do
          :ok
        else
          {:error, reason} -> {:error, Error.invalid_run_args(reason)}
        end
    end
  end

  defp ensure_resume_args_absent(params) do
    case fetch_param(params, :args, "args") do
      :missing -> :ok
      {:ok, _args} -> {:error, Error.resume_args_immutable()}
    end
  end

  defp supplied_args?(params), do: fetch_param(params, :args, "args") != :missing

  defp start_result({:ok, started_run_id, _pid}, _requested_run_id), do: {:ok, RunStart.accepted(started_run_id)}

  defp start_result({:error, {:already_running, _pid}}, run_id), do: {:error, Error.run_already_running(run_id)}

  defp start_result({:error, {:capacity_exceeded, max_active_runs}}, _run_id),
    do: {:error, Error.run_capacity_exceeded(max_active_runs)}

  defp start_result({:error, {:invalid_run_args, reason}}, _run_id), do: {:error, Error.invalid_run_args(reason)}

  defp start_result({:error, {:tree_fingerprint_mismatch, recorded, current}}, run_id),
    do: {:error, Error.workflow_changed(run_id, recorded, current)}

  defp start_result({:error, {:run_args_mismatch, recorded, supplied}}, run_id),
    do: {:error, Error.run_args_mismatch(run_id, recorded, supplied)}

  defp start_result({:error, reason}, _run_id), do: {:error, Error.run_start_failed(reason)}

  defp fetch_param(params, atom_key, string_key) do
    cond do
      Map.has_key?(params, string_key) -> {:ok, Map.fetch!(params, string_key)}
      Map.has_key?(params, atom_key) -> {:ok, Map.fetch!(params, atom_key)}
      true -> :missing
    end
  end

  defp application_started?(app) do
    Enum.any?(Application.started_applications(), fn
      {^app, _description, _version} -> true
      _other -> false
    end)
  end

  defp process_alive?(name) do
    case Process.whereis(name) do
      pid when is_pid(pid) -> Process.alive?(pid)
      nil -> false
    end
  end

  defp available?(true), do: :available
  defp available?(false), do: :unavailable
end
