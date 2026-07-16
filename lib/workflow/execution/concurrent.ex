defmodule Workflow.Execution.Concurrent do
  @moduledoc """
  Bounded, input-ordered workflow concurrency backed by ephemeral Reactor DAGs.

  The Reactor task is only a scheduling wrapper. Each lane's work runs under
  `Workflow.TaskSupervisor` and is guarded by the run owner, preserving hard
  cancellation when a writer dies. Results are returned in input order and
  expected workflow failures remain ordinary values for the writer to settle.
  """

  alias Workflow.Execution.Cancellation
  alias Workflow.Execution.FatalLatch
  alias Workflow.Execution.Plan
  alias Workflow.Execution.Queue
  alias Workflow.Execution.Reporter
  alias Workflow.Execution.Result
  alias Workflow.Execution.Step.Run

  @max_concurrency 8

  @spec run(Enumerable.t(), pos_integer(), pos_integer(), (term() -> term())) :: [term()]
  def run(inputs, cap, timeout, fun)
      when is_integer(cap) and cap > 0 and is_integer(timeout) and timeout > 0 and is_function(fun, 1) do
    inputs
    |> outcomes(cap, timeout, fun, fatal?: &fatal_result?/1)
    |> Enum.map(&unwrap!(&1, timeout))
  end

  @spec outcomes(Enumerable.t(), pos_integer(), timeout(), (term() -> term()), keyword()) :: [Result.t()]
  def outcomes(inputs, cap, timeout, fun, opts \\ [])
      when is_integer(cap) and cap > 0 and (timeout == :infinity or (is_integer(timeout) and timeout > 0)) and
             is_function(fun, 1) do
    owner = self()
    inputs = Enum.to_list(inputs)
    fatal? = Keyword.get(opts, :fatal?, fn _result -> false end)

    run_all(inputs, min(cap, @max_concurrency), timeout, fun, owner, fatal?)
  end

  @doc false
  @spec deliver(pid(), reference(), non_neg_integer(), Result.t(), pid()) :: :ok
  def deliver(owner, execution_ref, index, result, step)
      when is_pid(owner) and is_reference(execution_ref) and is_integer(index) and index >= 0 and is_pid(step) do
    send(owner, {:workflow_execution_result, execution_ref, index, result, step})
    :ok
  end

  defp run_all([], _cap, _timeout, _fun, _owner, _fatal?), do: []

  defp run_all(inputs, cap, timeout, fun, owner, fatal?) do
    dependencies = monitor_dependencies!()
    {:ok, supervisor} = Task.Supervisor.start_link()

    try do
      {:ok, cancellation} = Cancellation.start(supervisor, owner)
      {:ok, reporter} = Reporter.start(supervisor, owner)

      run_supervised(
        inputs,
        cap,
        timeout,
        fun,
        owner,
        fatal?,
        dependencies,
        supervisor,
        cancellation,
        reporter
      )
    after
      stop_supervisor(supervisor)
      Enum.each(dependencies, fn {ref, _name, _pid} -> Process.demonitor(ref, [:flush]) end)
    end
  end

  defp run_supervised(inputs, cap, timeout, fun, owner, fatal?, dependencies, supervisor, cancellation, reporter) do
    latch = FatalLatch.new()
    {:ok, queue} = Queue.start(supervisor, inputs, owner, cancellation, latch)
    execution_ref = make_ref()

    run_dependencies =
      monitor_processes([
        {Cancellation, cancellation},
        {Queue, queue},
        {Reporter, reporter}
      ])

    try do
      task =
        Task.Supervisor.async_nolink(supervisor, fn ->
          inputs
          |> Plan.build(fun, owner, timeout,
            cancellation: cancellation,
            queue: queue,
            report_to: reporter,
            execution_ref: execution_ref,
            fatal?: fatal?,
            max_concurrency: cap,
            supervisor: supervisor,
            latch: latch
          )
          |> Reactor.run(%{}, %{}, max_concurrency: cap)
        end)

      case await_reactor(
             task,
             run_dependencies ++ dependencies,
             supervisor,
             execution_ref,
             fatal?,
             length(inputs),
             nil,
             %{},
             0,
             []
           ) do
        {:reactor, result} -> reactor_results!(result)
        {:fatal, results} -> results
      end
    after
      Enum.each(run_dependencies, fn {ref, _name, _pid} -> Process.demonitor(ref, [:flush]) end)
    end
  end

  defp monitor_processes(processes) do
    Enum.map(processes, fn {name, pid} -> {Process.monitor(pid), name, pid} end)
  end

  defp monitor_dependencies! do
    case Workflow.Execution.dependency_processes() do
      {:ok, dependencies} ->
        Enum.map(dependencies, fn {name, pid} -> {Process.monitor(pid), name, pid} end)

      {:error, reason} ->
        exit({:reactor_dependency_unavailable, reason})
    end
  end

  defp await_reactor(
         %Task{ref: task_ref, pid: task_pid} = task,
         dependencies,
         supervisor,
         execution_ref,
         fatal?,
         total,
         reactor_result,
         buffered,
         next_index,
         ordered
       ) do
    receive do
      {^task_ref, result} ->
        _ = Task.ignore(task)

        case result do
          {:ok, _results} when next_index == total ->
            {:reactor, result}

          {:ok, _results} ->
            await_reactor(
              task,
              dependencies,
              supervisor,
              execution_ref,
              fatal?,
              total,
              result,
              buffered,
              next_index,
              ordered
            )

          _failure ->
            abort_run(supervisor, task, execution_ref)
            {:reactor, result}
        end

      {:workflow_execution_result, ^execution_ref, index, result, step} ->
        buffered = Map.put(buffered, index, {result, step})

        case drain_ordered(buffered, next_index, ordered, fatal?) do
          {:fatal, results, fatal_index, fatal_step} ->
            Run.acknowledge(fatal_step, execution_ref, fatal_index)
            abort_run(supervisor, task, execution_ref)
            {:fatal, results}

          {:continue, buffered, next_index, ordered} ->
            if next_index == total and not is_nil(reactor_result) do
              {:reactor, reactor_result}
            else
              await_reactor(
                task,
                dependencies,
                supervisor,
                execution_ref,
                fatal?,
                total,
                reactor_result,
                buffered,
                next_index,
                ordered
              )
            end
        end

      {:DOWN, ^task_ref, :process, ^task_pid, {%_{} = exception, stacktrace}}
      when is_list(stacktrace) ->
        abort_run(supervisor, task, execution_ref)
        reraise exception, stacktrace

      {:DOWN, ^task_ref, :process, ^task_pid, reason} ->
        abort_run(supervisor, task, execution_ref)
        exit({:reactor_execution_crashed, reason})

      {:DOWN, dependency_ref, :process, dependency_pid, reason} ->
        case List.keyfind(dependencies, dependency_ref, 0) do
          {^dependency_ref, name, ^dependency_pid} ->
            abort_run(supervisor, task, execution_ref)
            exit({:reactor_dependency_down, name, reason})

          nil ->
            await_reactor(
              task,
              dependencies,
              supervisor,
              execution_ref,
              fatal?,
              total,
              reactor_result,
              buffered,
              next_index,
              ordered
            )
        end
    end
  end

  defp abort_run(supervisor, task, execution_ref) do
    stop_supervisor(supervisor)
    _ = Task.ignore(task)
    flush_execution_reports(execution_ref)
  end

  defp stop_supervisor(supervisor) do
    Supervisor.stop(supervisor, :normal, 10_000)
  catch
    :exit, _reason -> :ok
  end

  defp flush_execution_reports(execution_ref) do
    receive do
      {:workflow_execution_result, ^execution_ref, _index, _result, _step} ->
        flush_execution_reports(execution_ref)
    after
      0 -> :ok
    end
  end

  defp drain_ordered(buffered, next_index, ordered, fatal?) do
    case Map.pop(buffered, next_index) do
      {nil, _buffered} ->
        {:continue, buffered, next_index, ordered}

      {{result, step}, buffered} ->
        ordered = [result | ordered]

        if fatal?.(result) do
          {:fatal, Enum.reverse(ordered), next_index, step}
        else
          drain_ordered(buffered, next_index + 1, ordered, fatal?)
        end
    end
  end

  defp reactor_results!({:ok, results}) when is_list(results), do: results

  defp reactor_results!({:error, reason}),
    do: raise("Reactor execution failed: #{Exception.format_banner(:error, reason)}")

  defp reactor_results!({:halted, _reactor}), do: raise("Reactor execution halted unexpectedly")

  defp fatal_result?(result), do: Result.fatal?(result)
  defp unwrap!(result, timeout), do: Result.unwrap!(result, timeout)
end
