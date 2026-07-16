defmodule Workflow.Execution.Step.Run do
  @moduledoc false
  use Reactor.Step

  alias Workflow.Execution.FatalLatch
  alias Workflow.Execution.Guardian
  alias Workflow.Execution.Queue
  alias Workflow.Execution.Reporter
  alias Workflow.Execution.Result

  @impl true
  def run(_arguments, _context, opts) do
    fun = Keyword.fetch!(opts, :fun)
    owner = Keyword.fetch!(opts, :owner)
    timeout = Keyword.fetch!(opts, :timeout)
    cancellation = Keyword.fetch!(opts, :cancellation)
    queue = Keyword.fetch!(opts, :queue)
    report_to = Keyword.fetch!(opts, :report_to)
    execution_ref = Keyword.fetch!(opts, :execution_ref)
    fatal? = Keyword.fetch!(opts, :fatal?)
    supervisor = Keyword.fetch!(opts, :supervisor)
    latch = Keyword.fetch!(opts, :latch)

    run_next(
      queue,
      fun,
      owner,
      timeout,
      cancellation,
      report_to,
      execution_ref,
      fatal?,
      supervisor,
      latch,
      []
    )
  end

  @doc false
  @spec execute(pid()) :: :ok
  def execute(worker) when is_pid(worker) do
    send(worker, :execute)
    :ok
  end

  @doc false
  @spec acknowledge(pid(), reference(), non_neg_integer()) :: :ok
  def acknowledge(step, execution_ref, index)
      when is_pid(step) and is_reference(execution_ref) and is_integer(index) and index >= 0 do
    send(step, {:workflow_execution_ack, execution_ref, index})
    :ok
  end

  defp run_next(queue, fun, owner, timeout, cancellation, report_to, execution_ref, fatal?, supervisor, latch, results) do
    case Queue.next(queue) do
      {:ok, index, item} ->
        result = execute(item, fun, owner, timeout, cancellation, supervisor, fatal?, latch)
        fatal = fatal?.(result)

        if fatal do
          FatalLatch.cancel(latch)

          case Queue.cancel(queue) do
            :ok -> :ok
            {:error, reason} -> exit({:execution_queue_cancel_failed, reason})
          end
        end

        Reporter.report(report_to, execution_ref, index, result, self())

        if fatal do
          await_fatal_ack(cancellation, execution_ref, index)
          {:error, {:workflow_fatal, result}}
        else
          run_next(
            queue,
            fun,
            owner,
            timeout,
            cancellation,
            report_to,
            execution_ref,
            fatal?,
            supervisor,
            latch,
            [{index, result} | results]
          )
        end

      :empty ->
        {:ok, Enum.reverse(results)}

      :cancelled ->
        {:ok, Enum.reverse(results)}
    end
  end

  defp execute(item, fun, owner, timeout, cancellation, supervisor, fatal?, latch) do
    step = self()

    task =
      Task.Supervisor.async_nolink(supervisor, fn ->
        receive do
          :execute -> capture(item, fun, fatal?, latch)
        end
      end)

    case Guardian.start(supervisor, task.pid, step, owner, cancellation) do
      {:ok, _guardian} ->
        await(task, timeout, fatal?, latch)

      {:error, reason} ->
        Task.shutdown(task, :brutal_kill)
        Result.exit({:guardian_start_failed, reason})
    end
  end

  defp await(task, timeout, fatal?, latch) do
    case Task.yield(task, timeout) do
      {:ok, result} ->
        result

      {:exit, {%_{} = exception, stacktrace}} when is_list(stacktrace) ->
        exception
        |> Result.exception(stacktrace)
        |> signal_if_fatal(fatal?, latch)

      {:exit, reason} ->
        reason
        |> Result.exit()
        |> signal_if_fatal(fatal?, latch)

      nil ->
        _ = Task.shutdown(task, :brutal_kill)
        signal_if_fatal(Result.timeout(), fatal?, latch)
    end
  end

  defp capture(item, fun, fatal?, latch) do
    result =
      try do
        Result.ok(fun.(item))
      rescue
        exception -> Result.exception(exception, __STACKTRACE__)
      catch
        :exit, reason -> Result.exit(reason)
        :throw, reason -> Result.exit({{:nocatch, reason}, __STACKTRACE__})
      end

    signal_if_fatal(result, fatal?, latch)
  end

  defp signal_if_fatal(result, fatal?, latch) do
    if fatal?.(result), do: FatalLatch.cancel(latch)
    result
  end

  defp await_fatal_ack(cancellation, execution_ref, index) do
    cancellation_ref = Process.monitor(cancellation)

    receive do
      {:workflow_execution_ack, ^execution_ref, ^index} ->
        Process.demonitor(cancellation_ref, [:flush])
        :ok

      {:DOWN, ^cancellation_ref, :process, ^cancellation, _reason} ->
        :ok
    end
  end
end
