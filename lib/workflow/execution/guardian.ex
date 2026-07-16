defmodule Workflow.Execution.Guardian do
  @moduledoc false

  alias Workflow.Execution.Step.Run

  @ready_timeout 1_000

  @spec start(Supervisor.supervisor(), pid(), pid(), pid(), pid()) :: {:ok, pid()} | {:error, term()}
  def start(supervisor, worker, step, owner, cancellation)
      when is_pid(worker) and is_pid(step) and is_pid(owner) and is_pid(cancellation) do
    caller = self()

    with {:ok, guardian} <-
           Task.Supervisor.start_child(supervisor, fn ->
             monitor(worker, step, owner, cancellation, caller)
           end) do
      receive do
        {:guardian_ready, ^guardian, :ok} ->
          {:ok, guardian}

        {:guardian_ready, ^guardian, {:error, reason}} ->
          {:error, reason}
      after
        @ready_timeout ->
          Task.Supervisor.terminate_child(supervisor, guardian)
          {:error, :guardian_start_timeout}
      end
    end
  end

  defp monitor(worker, step, owner, cancellation, caller) do
    worker_ref = Process.monitor(worker)
    step_ref = Process.monitor(step)
    owner_ref = Process.monitor(owner)
    cancellation_ref = Process.monitor(cancellation)

    if Enum.all?([worker, step, owner, cancellation], &Process.alive?/1) do
      Run.execute(worker)
      send(caller, {:guardian_ready, self(), :ok})
      await_down(worker, worker_ref, step, step_ref, owner, owner_ref, cancellation, cancellation_ref)
    else
      Process.exit(worker, :kill)
      send(caller, {:guardian_ready, self(), {:error, :execution_cancelled}})
    end
  end

  defp await_down(worker, worker_ref, step, step_ref, owner, owner_ref, cancellation, cancellation_ref) do
    receive do
      {:DOWN, ^worker_ref, :process, ^worker, _reason} ->
        :ok

      {:DOWN, ^step_ref, :process, ^step, _reason} ->
        Process.exit(worker, :kill)

      {:DOWN, ^owner_ref, :process, ^owner, _reason} ->
        Process.exit(worker, :kill)

      {:DOWN, ^cancellation_ref, :process, ^cancellation, _reason} ->
        Process.exit(worker, :kill)
    end
  end
end
