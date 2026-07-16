defmodule Workflow.Execution.Queue do
  @moduledoc false

  alias Workflow.Execution.FatalLatch

  @ready_timeout 1_000

  @spec start(Supervisor.supervisor(), [term()], pid(), pid(), FatalLatch.t()) ::
          {:ok, pid()} | {:error, term()}
  def start(supervisor, items, owner, cancellation, latch)
      when is_list(items) and is_pid(owner) and is_pid(cancellation) do
    caller = self()
    indexed_items = Enum.with_index(items, fn item, index -> {index, item} end)

    with {:ok, pid} <-
           Task.Supervisor.start_child(supervisor, fn ->
             initialize(indexed_items, owner, cancellation, latch, caller)
           end) do
      receive do
        {:execution_queue_ready, ^pid, :ok} -> {:ok, pid}
        {:execution_queue_ready, ^pid, {:error, reason}} -> {:error, reason}
      after
        @ready_timeout ->
          Task.Supervisor.terminate_child(supervisor, pid)
          {:error, :execution_queue_start_timeout}
      end
    end
  end

  @spec next(pid()) :: {:ok, non_neg_integer(), term()} | :empty | :cancelled
  def next(queue) when is_pid(queue) do
    monitor = Process.monitor(queue)
    request = make_ref()
    send(queue, {:next, self(), request})

    receive do
      {:execution_queue, ^request, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^queue, _reason} ->
        :cancelled
    end
  end

  @spec cancel(pid()) :: :ok | {:error, term()}
  def cancel(queue) when is_pid(queue) do
    monitor = Process.monitor(queue)
    request = make_ref()
    send(queue, {:cancel, self(), request})

    receive do
      {:execution_queue_cancelled, ^request} ->
        Process.demonitor(monitor, [:flush])
        :ok

      {:DOWN, ^monitor, :process, ^queue, _reason} ->
        :ok
    after
      @ready_timeout ->
        Process.demonitor(monitor, [:flush])
        {:error, :queue_cancel_timeout}
    end
  end

  defp initialize(items, owner, cancellation, latch, caller) do
    owner_ref = Process.monitor(owner)
    cancellation_ref = Process.monitor(cancellation)

    if Process.alive?(owner) and Process.alive?(cancellation) do
      send(caller, {:execution_queue_ready, self(), :ok})
      loop(items, owner, owner_ref, cancellation, cancellation_ref, latch)
    else
      send(caller, {:execution_queue_ready, self(), {:error, :execution_cancelled}})
    end
  end

  defp loop(items, owner, owner_ref, cancellation, cancellation_ref, latch) do
    receive do
      {:next, caller, request} when is_pid(caller) ->
        if FatalLatch.cancelled?(latch) do
          send(caller, {:execution_queue, request, :cancelled})
          cancelled(owner, owner_ref, cancellation, cancellation_ref)
        else
          case items do
            [{index, item} | rest] ->
              send(caller, {:execution_queue, request, {:ok, index, item}})
              loop(rest, owner, owner_ref, cancellation, cancellation_ref, latch)

            [] ->
              send(caller, {:execution_queue, request, :empty})
              loop([], owner, owner_ref, cancellation, cancellation_ref, latch)
          end
        end

      {:cancel, caller, request} when is_pid(caller) ->
        send(caller, {:execution_queue_cancelled, request})
        cancelled(owner, owner_ref, cancellation, cancellation_ref)

      {:DOWN, ^owner_ref, :process, ^owner, _reason} ->
        :ok

      {:DOWN, ^cancellation_ref, :process, ^cancellation, _reason} ->
        :ok
    end
  end

  defp cancelled(owner, owner_ref, cancellation, cancellation_ref) do
    receive do
      {:next, caller, request} when is_pid(caller) ->
        send(caller, {:execution_queue, request, :cancelled})
        cancelled(owner, owner_ref, cancellation, cancellation_ref)

      {:cancel, caller, request} when is_pid(caller) ->
        send(caller, {:execution_queue_cancelled, request})
        cancelled(owner, owner_ref, cancellation, cancellation_ref)

      {:DOWN, ^owner_ref, :process, ^owner, _reason} ->
        :ok

      {:DOWN, ^cancellation_ref, :process, ^cancellation, _reason} ->
        :ok
    end
  end
end
