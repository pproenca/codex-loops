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
  alias Workflow.Run.Options
  alias Workflow.Run.Writer
  alias Workflow.Tree

  @spec start(Tree.t(), [Options.option()] | Options.t()) ::
          {:ok, String.t(), pid()} | {:error, term()}
  def start(%Tree{} = tree, options) when is_list(options) do
    with {:ok, options} <- Options.from_keyword(options), do: start(tree, options)
  end

  def start(%Tree{} = tree, %Options{} = options) do
    with {:ok, run_id, pid} <- spawn_writer(tree, options, nil) do
      :ok = Writer.start_execution(pid)
      {:ok, run_id, pid}
    end
  end

  @spec run(Tree.t(), [Options.option()] | Options.t()) :: {:ok, String.t()} | {:error, term()}
  def run(%Tree{} = tree, options) when is_list(options) do
    with {:ok, options} <- Options.from_keyword(options), do: run(tree, options)
  end

  def run(%Tree{} = tree, %Options{} = options) do
    with {:ok, run_id, pid} <- spawn_writer(tree, options, self()) do
      Writer.run_to_completion(pid, run_id)
    end
  end

  # Claim the write lease and return the idle writer's pid without starting work.
  defp spawn_writer(%Tree{} = tree, %Options{} = options, parent) do
    # Index the run at its creation point so read commands can enumerate it and
    # select the latest. Idempotent, so a resume of an existing run is a no-op.
    :ok = Journal.register_run(options.run_id)

    case DynamicSupervisor.start_child(Workflow.Run.Supervisor, {Writer, {tree, options, parent}}) do
      {:ok, pid} -> {:ok, options.run_id, pid}
      {:error, {:already_started, pid}} -> {:error, {:already_running, pid}}
      {:error, reason} -> {:error, reason}
    end
  end
end
