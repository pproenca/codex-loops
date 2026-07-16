defmodule Workflow.Execution.Reporter do
  @moduledoc false

  alias Workflow.Execution.Concurrent
  alias Workflow.Execution.Result

  @ready_timeout 1_000

  @spec start(Supervisor.supervisor(), pid()) :: {:ok, pid()} | {:error, term()}
  def start(supervisor, owner) when is_pid(owner) do
    caller = self()

    with {:ok, reporter} <-
           Task.Supervisor.start_child(supervisor, fn ->
             initialize(owner, caller)
           end) do
      receive do
        {:execution_reporter_ready, ^reporter, :ok} -> {:ok, reporter}
        {:execution_reporter_ready, ^reporter, {:error, reason}} -> {:error, reason}
      after
        @ready_timeout ->
          Task.Supervisor.terminate_child(supervisor, reporter)
          {:error, :execution_reporter_start_timeout}
      end
    end
  end

  @spec report(pid(), reference(), non_neg_integer(), Result.t(), pid()) :: :ok
  def report(reporter, execution_ref, index, result, step)
      when is_pid(reporter) and is_reference(execution_ref) and is_integer(index) and index >= 0 and is_pid(step) do
    send(reporter, {:workflow_execution_result, execution_ref, index, result, step})
    :ok
  end

  defp initialize(owner, caller) do
    owner_ref = Process.monitor(owner)

    if Process.alive?(owner) do
      send(caller, {:execution_reporter_ready, self(), :ok})
      forward(owner, owner_ref)
    else
      send(caller, {:execution_reporter_ready, self(), {:error, :owner_down}})
    end
  end

  defp forward(owner, owner_ref) do
    receive do
      {:workflow_execution_result, execution_ref, index, result, step} ->
        Concurrent.deliver(owner, execution_ref, index, result, step)
        forward(owner, owner_ref)

      {:DOWN, ^owner_ref, :process, ^owner, _reason} ->
        :ok
    end
  end
end
