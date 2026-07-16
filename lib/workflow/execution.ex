defmodule Workflow.Execution do
  @moduledoc """
  Runtime boundary for ephemeral Reactor execution.

  Reactor starts before the scheduler application. Health is available only
  while its task supervisor, concurrency tracker, and tracker-owned ETS table
  are all live. Individual runs monitor the same processes while executing, so
  replacement aborts that execution instead of leaving it on a stale pool.
  """

  alias Reactor.Executor.ConcurrencyTracker

  @readiness_timeout 100

  @spec available?() :: boolean()
  def available?, do: match?({:ok, _dependencies}, dependency_processes())

  @spec dependency_processes() :: {:ok, [{term(), pid()}]} | {:error, term()}
  def dependency_processes do
    if :ets.whereis(ConcurrencyTracker) == :undefined do
      {:error, :dependency_unavailable}
    else
      find_dependency_processes()
    end
  end

  defp find_dependency_processes do
    with task_supervisor when is_pid(task_supervisor) <- Process.whereis(Reactor.TaskSupervisor),
         tracker when is_pid(tracker) <- Process.whereis(ConcurrencyTracker),
         {:ok, partitions} <- partitions(task_supervisor) do
      dependencies =
        [
          {Reactor.TaskSupervisor, task_supervisor},
          {ConcurrencyTracker, tracker}
        ] ++
          Enum.map(partitions, fn {id, pid, _type, _modules} ->
            {{:reactor_task_partition, id}, pid}
          end)

      if Enum.all?(dependencies, fn {_name, pid} -> responsive?(pid) end) do
        {:ok, dependencies}
      else
        {:error, :dependency_unresponsive}
      end
    else
      nil -> {:error, :dependency_unavailable}
      {:error, _reason} = error -> error
    end
  end

  defp partitions(task_supervisor) do
    task =
      Task.Supervisor.async_nolink(Workflow.TaskSupervisor, fn ->
        Supervisor.which_children(task_supervisor)
      end)

    case Task.yield(task, @readiness_timeout) do
      {:ok, partitions} when is_list(partitions) ->
        {:ok, partitions}

      {:exit, reason} ->
        {:error, reason}

      nil ->
        _ = Task.shutdown(task, :brutal_kill)
        {:error, :partition_lookup_timeout}
    end
  catch
    :exit, reason -> {:error, reason}
  end

  defp responsive?(pid) when is_pid(pid) do
    match?({:status, ^pid, _module, [_dictionary, :running | _details]}, :sys.get_status(pid, @readiness_timeout))
  catch
    :exit, _reason -> false
  end
end
