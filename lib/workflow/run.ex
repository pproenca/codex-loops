defmodule Workflow.Run do
  @moduledoc """
  Public API for executing a workflow. Accepts a compiled `%Workflow.Tree{}` or a
  module that `use`s `Workflow`.

    * `start/2` — claim the write lease and begin executing asynchronously.
      Returns `{:error, {:already_running, pid}}` if a live writer already holds
      the run's lease.
    * `run/2` — `start/2` then block until the run finishes, returning
      `{:ok, run_id}`. Read state back with `Workflow.Status.of/1`.
  """

  alias Workflow.{Tree, Run}

  @type option ::
          {:run_id, String.t()}
          | {:provider, {module(), term()}}
          | {:budget, non_neg_integer()}

  @spec start(Tree.t() | module(), [option()]) ::
          {:ok, String.t(), pid()} | {:error, term()}
  def start(workflow, opts) do
    with {:ok, run_id, pid} <- spawn_writer(workflow, opts) do
      # The writer holds its lease but idles until told to `:begin`; releasing it
      # here starts the work now that the caller has the pid.
      send(pid, :begin)
      {:ok, run_id, pid}
    end
  end

  @spec run(Tree.t() | module(), [option()]) :: {:ok, String.t()} | {:error, term()}
  def run(workflow, opts) do
    with {:ok, run_id, pid} <- spawn_writer(workflow, opts) do
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
  defp spawn_writer(%Tree{} = tree, opts) do
    run_id = Keyword.get(opts, :run_id) || generate_run_id()
    provider = Keyword.fetch!(opts, :provider)
    budget = Keyword.get(opts, :budget)

    spec =
      {Run.Writer, run_id: run_id, tree: tree, provider: provider, budget: budget, parent: self()}

    case DynamicSupervisor.start_child(Workflow.Run.Supervisor, spec) do
      {:ok, pid} -> {:ok, run_id, pid}
      {:error, {:already_started, pid}} -> {:error, {:already_running, pid}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp spawn_writer(module, opts) when is_atom(module),
    do: spawn_writer(module.__workflow__(:tree), opts)

  defp generate_run_id, do: "run_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
end
