defmodule Workflow.Run do
  @moduledoc """
  Public API for executing an already compiled `%Workflow.Tree{}`.

    * `start/2` — claim the write lease and begin executing asynchronously.
      Returns `{:error, {:already_running, pid}}` if a live writer already holds
      the run's lease.
    * `run/2` — `start/2` then block until the run finishes, returning
      `{:ok, run_id}`. Read state back with `Workflow.Status.of/1`.
  """

  alias Workflow.Journal
  alias Workflow.Provider
  alias Workflow.Run
  alias Workflow.Tree

  @type option ::
          {:run_id, String.t()}
          | {:provider, {module(), term()}}
          | {:budget, non_neg_integer()}
          | {:script_path, String.t()}

  @spec start(Tree.t(), [option()]) ::
          {:ok, String.t(), pid()} | {:error, term()}
  def start(%Tree{} = tree, opts) do
    with {:ok, run_id, pid} <- spawn_writer(tree, opts, nil) do
      # The writer holds its lease but idles until told to `:begin`; releasing it
      # here starts the work now that the caller has the pid.
      send(pid, :begin)
      {:ok, run_id, pid}
    end
  end

  @spec run(Tree.t(), [option()]) :: {:ok, String.t()} | {:error, term()}
  def run(%Tree{} = tree, opts) do
    with {:ok, run_id, pid} <- spawn_writer(tree, opts, self()) do
      # Monitor *before* the writer runs a single effect: the writer idles until it
      # receives `:begin`, so this ordering guarantees the monitor is in place
      # before any provider call (or a mid-turn crash) can happen. Without it, a
      # writer that dies before we monitor would deliver a `:noproc` DOWN instead of
      # the real exit reason — making the crash-window contract race.
      ref = Process.monitor(pid)
      send(pid, :begin)

      receive do
        {:run_finished, ^run_id, result} ->
          Process.demonitor(ref, [:flush])
          result

        {:DOWN, ^ref, :process, ^pid, :normal} ->
          {:ok, run_id}

        {:DOWN, ^ref, :process, ^pid, reason} ->
          {:error, {:run_crashed, reason}}
      end
    end
  end

  # Claim the write lease and return the idle writer's pid without starting work.
  defp spawn_writer(%Tree{} = tree, opts, parent) do
    with {:ok, run_id} <- resolve_run_id(opts),
         {:ok, budget} <- resolve_budget(opts),
         {:ok, script_path} <- resolve_script_path(opts),
         {:ok, provider} <- resolve_provider(opts) do
      # Index the run at its creation point so read commands can enumerate it and
      # select the latest. Idempotent, so a resume of an existing run is a no-op.
      :ok = Journal.register_run(run_id)

      spec =
        {Run.Writer,
         run_id: run_id, tree: tree, provider: provider, budget: budget, script_path: script_path, parent: parent}

      case DynamicSupervisor.start_child(Workflow.Run.Supervisor, spec) do
        {:ok, pid} -> {:ok, run_id, pid}
        {:error, {:already_started, pid}} -> {:error, {:already_running, pid}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp resolve_provider(opts) do
    opts
    |> Keyword.get(:provider)
    |> Provider.resolve()
  end

  defp resolve_run_id(opts) do
    case Keyword.get(opts, :run_id) do
      nil -> {:ok, generate_run_id()}
      run_id when is_binary(run_id) and byte_size(run_id) > 0 -> {:ok, :binary.copy(run_id)}
      _invalid -> {:error, {:usage, :run_id}}
    end
  end

  defp resolve_budget(opts) do
    case Keyword.get(opts, :budget) do
      nil -> {:ok, nil}
      budget when is_integer(budget) and budget >= 0 -> {:ok, budget}
      _invalid -> {:error, {:usage, :budget}}
    end
  end

  defp resolve_script_path(opts) do
    case Keyword.get(opts, :script_path) do
      nil -> {:ok, nil}
      path when is_binary(path) and byte_size(path) > 0 -> {:ok, :binary.copy(path)}
      _invalid -> {:error, {:usage, :script_path}}
    end
  end

  defp generate_run_id, do: "run_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
end
