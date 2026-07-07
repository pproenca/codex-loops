defmodule Workflow.Scheduler do
  @moduledoc """
  Product API boundary for scheduler clients.

  Phoenix controllers call this context instead of reaching into journal or runtime
  internals. Expected API failures return tagged tuples with typed error data;
  unexpected process failures are left to crash under supervision.
  """

  alias Workflow.{Journal, Provider, Run, Script, Status}

  alias Workflow.Scheduler.{
    Error,
    Health,
    RunEventsProjection,
    RunProjection,
    RunStart,
    Validation
  }

  @app :codex_loops
  @supported_providers ["mock", "codex"]

  @spec health() :: {:ok, Health.t()} | {:error, Error.t()}
  def health do
    checks = %{
      otp_app: available?(application_started?(@app)),
      journal: available?(process_alive?(Workflow.Journal)),
      pubsub: available?(process_alive?(Workflow.PubSub)),
      endpoint: available?(process_alive?(Workflow.Web.Endpoint))
    }

    if Enum.all?(checks, fn {_dependency, status} -> status == :available end) do
      {:ok, %Health{status: :ok, checks: checks}}
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
         {:ok, tree} <- Script.load_tree(path) do
      opts =
        [provider: provider, budget: budget, script_path: Path.expand(path)]
        |> put_run_id(run_id)

      case Run.start(tree, opts) do
        {:ok, started_run_id, _pid} ->
          {:ok, RunStart.accepted(started_run_id)}

        {:error, {:already_running, _pid}} ->
          {:error, Error.run_already_running(run_id)}

        {:error, reason} ->
          {:error, Error.run_start_failed(reason)}
      end
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
         {:ok, provider} <- run_provider(params),
         :ok <- ensure_not_running(run_id),
         {:ok, path} <- resume_script_path(run_id, params),
         {:ok, tree} <- Script.load_tree(path) do
      case Run.start(tree,
             run_id: run_id,
             provider: provider,
             script_path: Path.expand(path)
           ) do
        {:ok, ^run_id, _pid} ->
          {:ok, RunStart.accepted(run_id)}

        {:error, {:already_running, _pid}} ->
          {:error, Error.run_already_running(run_id)}

        {:error, reason} ->
          {:error, Error.run_start_failed(reason)}
      end
    else
      {:error, %Workflow.Script.Error{} = error} -> {:error, Error.workflow_validation(error)}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  def resume_run(_run_id, _params), do: {:error, Error.invalid_run_id()}

  @spec get_run(String.t()) :: {:ok, RunProjection.t()} | {:error, Error.t()}
  def get_run(run_id) when is_binary(run_id) and byte_size(run_id) > 0 do
    if run_id in Journal.run_ids() do
      {:ok, run_projection(run_id)}
    else
      {:error, Error.run_not_found(run_id)}
    end
  end

  def get_run(_run_id), do: {:error, Error.invalid_run_id()}

  @type run_snapshot :: %{status: Status.t(), run_projection: RunProjection.t()}

  @doc """
  Returns the complete scheduler-owned read model for one render.

  The journal is folded once, then both the workflow status body and lifecycle
  projection are derived from those events plus the current runtime lease fact.
  """
  @spec get_run_snapshot(String.t()) :: {:ok, run_snapshot()} | {:error, Error.t()}
  def get_run_snapshot(run_id) when is_binary(run_id) and byte_size(run_id) > 0 do
    {:ok, run_snapshot(run_id)}
  end

  def get_run_snapshot(_run_id), do: {:error, Error.invalid_run_id()}

  @spec get_run_events(String.t()) :: {:ok, RunEventsProjection.t()} | {:error, Error.t()}
  def get_run_events(run_id) when is_binary(run_id) and byte_size(run_id) > 0 do
    if run_id in Journal.run_ids() do
      {:ok, RunEventsProjection.from_events(run_id, Journal.fold(run_id))}
    else
      {:error, Error.run_not_found(run_id)}
    end
  end

  def get_run_events(_run_id), do: {:error, Error.invalid_run_id()}

  @spec validate_workflow(map()) :: {:ok, Validation.t()} | {:error, Error.t()}
  def validate_workflow(%{"script_path" => path}) when is_binary(path),
    do: validate_workflow_path(path)

  def validate_workflow(%{script_path: path}) when is_binary(path),
    do: validate_workflow_path(path)

  def validate_workflow(%{"script" => path}) when is_binary(path),
    do: validate_workflow_path(path)

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
    case Enum.find(Journal.fold(run_id), &(&1.type == :run_started)) do
      %{payload: %{script_path: path}} when is_binary(path) and byte_size(path) > 0 ->
        {:ok, path}

      _missing_or_unrecorded ->
        {:error, Error.missing_script_path()}
    end
  end

  defp run_id(params) do
    case fetch_param(params, :run_id, "run_id") do
      :missing -> {:ok, nil}
      {:ok, id} when is_binary(id) and byte_size(id) > 0 -> route_safe_run_id(id)
      {:ok, _invalid} -> {:error, Error.invalid_run_id()}
    end
  end

  defp route_safe_run_id(id) do
    if Regex.match?(~r/^[A-Za-z0-9][A-Za-z0-9_.:-]*$/, id) do
      {:ok, id}
    else
      {:error, Error.invalid_run_id()}
    end
  end

  defp ensure_run_exists(run_id) do
    if run_id in Journal.run_ids() do
      :ok
    else
      {:error, Error.run_not_found(run_id)}
    end
  end

  defp ensure_not_running(run_id) do
    if run_running?(run_id) do
      {:error, Error.run_already_running(run_id)}
    else
      :ok
    end
  end

  defp run_projection(run_id) do
    %{run_projection: run_projection} = run_snapshot(run_id)
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

    %{status: status, run_projection: run_projection}
  end

  defp run_running?(run_id) do
    case Registry.lookup(Workflow.Run.Registry, run_id) do
      [] -> false
      [{_pid, _value} | _rest] -> true
    end
  end

  defp run_provider(params) do
    case fetch_param(params, :provider, "provider") do
      :missing -> {:ok, Provider.select(:mock, [])}
      {:ok, provider} when provider in ["mock", :mock] -> {:ok, Provider.select(:mock, [])}
      {:ok, provider} when provider in ["codex", :codex] -> {:ok, Provider.select(:codex, [])}
      {:ok, _unsupported} -> {:error, Error.invalid_provider(@supported_providers)}
    end
  end

  defp run_budget(params) do
    case fetch_param(params, :budget, "budget") do
      :missing -> {:ok, nil}
      {:ok, budget} when is_integer(budget) and budget >= 0 -> {:ok, budget}
      {:ok, _invalid} -> {:error, Error.invalid_budget()}
    end
  end

  defp fetch_param(params, atom_key, string_key) do
    cond do
      Map.has_key?(params, string_key) -> {:ok, Map.fetch!(params, string_key)}
      Map.has_key?(params, atom_key) -> {:ok, Map.fetch!(params, atom_key)}
      true -> :missing
    end
  end

  defp put_run_id(opts, nil), do: opts
  defp put_run_id(opts, run_id), do: Keyword.put(opts, :run_id, run_id)

  defp validate_workflow_path(path) do
    case Workflow.Script.load_tree(path) do
      {:ok, tree} -> {:ok, Validation.from_tree(tree, path)}
      {:error, error} -> {:error, Error.workflow_validation(error)}
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
