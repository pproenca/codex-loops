defmodule Workflow.ExecutionInfrastructureTest do
  use ExUnit.Case, async: false

  alias Reactor.Executor.ConcurrencyTracker
  alias Workflow.Execution.Concurrent
  alias Workflow.Execution.Queue
  alias Workflow.Scheduler.Error

  @receive_timeout 2_000

  @tag :capture_log
  test "a concurrency-tracker replacement aborts the run and kills its branch" do
    test_pid = self()

    task =
      Task.Supervisor.async_nolink(Workflow.TaskSupervisor, fn ->
        Concurrent.run([:work], 1, 5_000, fn _item ->
          send(test_pid, {:blocked, self()})
          receive do: (:never -> :ok)
        end)
      end)

    assert_receive {:blocked, worker}, @receive_timeout
    worker_ref = Process.monitor(worker)
    tracker = Process.whereis(ConcurrencyTracker)
    tracker_ref = Process.monitor(tracker)

    Process.exit(tracker, :kill)

    assert_receive {:DOWN, ^tracker_ref, :process, ^tracker, :killed}, @receive_timeout

    assert {:exit, {:reactor_dependency_down, ConcurrencyTracker, :killed}} =
             Task.yield(task, @receive_timeout)

    assert_receive {:DOWN, ^worker_ref, :process, ^worker, _reason}, @receive_timeout
    assert await_available?()
    assert Concurrent.run([:recovered], 1, 1_000, & &1) == [:recovered]
  end

  @tag :capture_log
  test "a Reactor task-supervisor replacement aborts the run and recovers" do
    test_pid = self()

    task =
      Task.Supervisor.async_nolink(Workflow.TaskSupervisor, fn ->
        Concurrent.run([:work], 1, 5_000, fn _item ->
          send(test_pid, {:task_supervisor_blocked, self()})
          receive do: (:never -> :ok)
        end)
      end)

    assert_receive {:task_supervisor_blocked, worker}, @receive_timeout
    worker_ref = Process.monitor(worker)
    task_supervisor = Process.whereis(Reactor.TaskSupervisor)
    task_supervisor_ref = Process.monitor(task_supervisor)

    Process.exit(task_supervisor, :kill)

    assert_receive {:DOWN, ^task_supervisor_ref, :process, ^task_supervisor, :killed}, @receive_timeout

    assert {:exit, {:reactor_dependency_down, dependency, _reason}} =
             Task.yield(task, @receive_timeout)

    assert dependency == Reactor.TaskSupervisor or match?({:reactor_task_partition, _id}, dependency)

    assert_receive {:DOWN, ^worker_ref, :process, ^worker, _reason}, @receive_timeout
    assert await_available?()
    assert Concurrent.run([:recovered], 1, 1_000, & &1) == [:recovered]
  end

  test "health fails closed when the concurrency tracker stops responding" do
    tracker = Process.whereis(ConcurrencyTracker)
    :ok = :sys.suspend(tracker)

    try do
      refute Workflow.Execution.available?()

      assert {:error,
              %Error{
                status: 503,
                code: "scheduler.unavailable",
                details: %{checks: %{execution: :unavailable}}
              }} = Workflow.Scheduler.health()
    after
      :ok = :sys.resume(tracker)
    end

    assert await_available?()
  end

  test "health fails closed when a Reactor task partition stops responding" do
    [{_id, partition, :supervisor, [Task.Supervisor]} | _rest] =
      Supervisor.which_children(Reactor.TaskSupervisor)

    :ok = :sys.suspend(partition)

    try do
      refute Workflow.Execution.available?()
      assert {:error, %Error{status: 503}} = Workflow.Scheduler.health()

      assert catch_exit(Concurrent.run([:must_not_start], 1, 1_000, & &1)) ==
               {:reactor_dependency_unavailable, :dependency_unresponsive}
    after
      :ok = :sys.resume(partition)
    end

    assert await_available?()
  end

  @tag :capture_log
  test "a queue crash aborts the run and synchronously kills paid work" do
    test_pid = self()

    task =
      Task.Supervisor.async_nolink(Workflow.TaskSupervisor, fn ->
        Concurrent.run([:blocked, :queued], 1, 5_000, fn item ->
          [run_supervisor] =
            self()
            |> Process.info(:links)
            |> elem(1)
            |> Enum.filter(&(Process.info(&1, :registered_name) == {:registered_name, []}))

          send(test_pid, {:queue_probe_started, item, self(), run_supervisor})
          receive do: (:never -> :ok)
        end)
      end)

    assert_receive {:queue_probe_started, :blocked, worker, run_supervisor}, @receive_timeout
    queue = await_child(run_supervisor, Queue)
    Process.exit(queue, :kill)

    assert {:exit, {:reactor_dependency_down, Queue, :killed}} =
             Task.yield(task, @receive_timeout)

    refute Process.alive?(worker)
    refute_receive {:queue_probe_started, :queued, _worker, _supervisor}, 100
  end

  defp await_available?(attempts \\ 200)
  defp await_available?(0), do: false

  defp await_available?(attempts) do
    if Workflow.Execution.available?() do
      true
    else
      Process.sleep(10)
      await_available?(attempts - 1)
    end
  end

  defp await_child(supervisor, module, attempts \\ 100)
  defp await_child(_supervisor, _module, 0), do: flunk("execution child did not start")

  defp await_child(supervisor, module, attempts) do
    case Enum.find(Task.Supervisor.children(supervisor), fn pid ->
           match?({:current_function, {^module, _function, _arity}}, Process.info(pid, :current_function))
         end) do
      nil ->
        Process.sleep(10)
        await_child(supervisor, module, attempts - 1)

      pid ->
        pid
    end
  end
end
