defmodule Workflow.Execution.Cancellation do
  @moduledoc false

  @ready_timeout 1_000

  @spec start(Supervisor.supervisor(), pid()) :: {:ok, pid()} | {:error, term()}
  def start(supervisor, owner) when is_pid(owner) do
    caller = self()

    with {:ok, pid} <-
           Task.Supervisor.start_child(supervisor, fn ->
             monitor_owner(owner, caller)
           end) do
      receive do
        {:cancellation_ready, ^pid, :ok} -> {:ok, pid}
        {:cancellation_ready, ^pid, {:error, reason}} -> {:error, reason}
      after
        @ready_timeout ->
          Task.Supervisor.terminate_child(supervisor, pid)
          {:error, :cancellation_start_timeout}
      end
    end
  end

  @spec cancel(pid()) :: :ok
  def cancel(pid) when is_pid(pid) do
    send(pid, :cancel)
    :ok
  end

  @spec complete(pid()) :: :ok
  def complete(pid) when is_pid(pid) do
    send(pid, :complete)
    :ok
  end

  defp monitor_owner(owner, caller) do
    owner_ref = Process.monitor(owner)

    if Process.alive?(owner) do
      send(caller, {:cancellation_ready, self(), :ok})

      receive do
        {:DOWN, ^owner_ref, :process, ^owner, _reason} -> :ok
        :cancel -> :ok
        :complete -> :ok
      end
    else
      send(caller, {:cancellation_ready, self(), {:error, :owner_down}})
    end
  end
end
