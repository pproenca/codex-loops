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

  @type option :: {:run_id, String.t()} | {:provider, {module(), term()}}

  @spec start(Tree.t() | module(), [option()]) ::
          {:ok, String.t(), pid()} | {:error, term()}
  def start(%Tree{} = tree, opts) do
    run_id = Keyword.get(opts, :run_id) || generate_run_id()
    provider = Keyword.fetch!(opts, :provider)

    spec = {Run.Writer, run_id: run_id, tree: tree, provider: provider, parent: self()}

    case DynamicSupervisor.start_child(Workflow.Run.Supervisor, spec) do
      {:ok, pid} -> {:ok, run_id, pid}
      {:error, {:already_started, pid}} -> {:error, {:already_running, pid}}
      {:error, reason} -> {:error, reason}
    end
  end

  def start(module, opts) when is_atom(module),
    do: start(module.__workflow__(:tree), opts)

  @spec run(Tree.t() | module(), [option()]) :: {:ok, String.t()} | {:error, term()}
  def run(workflow, opts) do
    with {:ok, run_id, pid} <- start(workflow, opts) do
      ref = Process.monitor(pid)

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

  defp generate_run_id, do: "run_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
end
