defmodule Workflow.ExecutionConcurrentTest do
  use ExUnit.Case, async: true

  alias Workflow.Execution.Concurrent

  @receive_timeout 2_000

  test "continuously refills the cap and returns results in input order" do
    test_pid = self()

    task =
      Task.Supervisor.async_nolink(Workflow.TaskSupervisor, fn ->
        Concurrent.run(1..3, 2, 5_000, fn item ->
          send(test_pid, {:started, item, self()})
          receive do: (:release -> item * 10)
        end)
      end)

    first = receive_started()
    second = receive_started()
    refute_receive {:started, 3, _pid}, 50

    {first_item, first_pid} = first
    send(first_pid, :release)

    assert_receive {:started, third_item, third_pid}, @receive_timeout
    refute third_item in [first_item, elem(second, 0)]

    send(elem(second, 1), :release)
    send(third_pid, :release)

    assert Task.await(task, @receive_timeout) == [10, 20, 30]
  end

  test "holds the production maximum at eight across a width of sixty-four" do
    test_pid = self()

    task =
      Task.Supervisor.async_nolink(Workflow.TaskSupervisor, fn ->
        Concurrent.run(1..64, 100, 5_000, fn item ->
          send(test_pid, {:wide_started, item, self()})
          receive do: (:release -> item)
        end)
      end)

    first_wave = for _index <- 1..8, do: receive_wide_started()
    refute_receive {:wide_started, _item, _pid}, 50
    Enum.each(first_wave, fn {_item, pid} -> send(pid, :release) end)

    for _index <- 9..64 do
      {_item, pid} = receive_wide_started()
      send(pid, :release)
    end

    assert Task.await(task, @receive_timeout) == Enum.to_list(1..64)
  end

  test "expected workflow failures remain ordinary ordered values" do
    assert Concurrent.run([:ok, :failed], 2, 1_000, fn
             :ok -> {:ok, [:event]}
             :failed -> {:failed, [:failure_event], :domain_failure}
           end) == [
             {:ok, [:event]},
             {:failed, [:failure_event], :domain_failure}
           ]
  end

  test "an effect-aware provider can own its deadline" do
    assert [%Workflow.Execution.Result.Ok{value: :settled}] =
             Concurrent.outcomes([:work], 1, :infinity, fn :work ->
               Process.sleep(20)
               :settled
             end)
  end

  @tag :capture_log
  test "re-raises a branch exception instead of converting it to a domain failure" do
    assert_raise RuntimeError, "branch exploded", fn ->
      Concurrent.run([:work], 1, 1_000, fn _item -> raise "branch exploded" end)
    end
  end

  @tag :capture_log
  test "a fatal branch cancels an in-flight sibling before returning" do
    test_pid = self()

    task =
      Task.Supervisor.async_nolink(Workflow.TaskSupervisor, fn ->
        Concurrent.run([:boom, :blocked], 2, 5_000, fn
          :boom ->
            send(test_pid, {:boom_ready, self()})
            receive do: (:explode -> raise("ordered boom"))

          :blocked ->
            send(test_pid, {:sibling_blocked, self()})
            receive do: (:finish -> send(test_pid, :late_sibling_effect))
        end)
      end)

    assert_receive {:boom_ready, boom}, @receive_timeout
    assert_receive {:sibling_blocked, sibling}, @receive_timeout
    sibling_ref = Process.monitor(sibling)
    send(boom, :explode)

    assert {:exit, {%RuntimeError{message: "ordered boom"}, stacktrace}} =
             Task.yield(task, @receive_timeout)

    assert is_list(stacktrace)
    refute Process.alive?(sibling)
    assert_receive {:DOWN, ^sibling_ref, :process, ^sibling, _reason}, @receive_timeout
    refute_receive :late_sibling_effect, 100
  end

  @tag :capture_log
  test "fatal cleanup leaves no execution reports in a rescuing caller mailbox" do
    assert_raise RuntimeError, "first failed", fn ->
      Concurrent.run([:boom, :blocked], 2, 5_000, fn
        :boom -> raise "first failed"
        :blocked -> receive do: (:never -> :ok)
      end)
    end

    refute_receive _message, 0
  end

  @tag :capture_log
  test "cap one admits the first fatal input before any later paid work" do
    test_pid = self()

    assert_raise RuntimeError, "first failed", fn ->
      Concurrent.run(1..20, 1, 1_000, fn
        1 -> raise "first failed"
        item -> send(test_pid, {:unexpected_later_input, item})
      end)
    end

    refute_received {:unexpected_later_input, _item}
  end

  @tag :capture_log
  test "a later fatal result closes admission while an earlier input settles" do
    test_pid = self()

    task =
      Task.Supervisor.async_nolink(Workflow.TaskSupervisor, fn ->
        Concurrent.run(0..19, 3, 5_000, fn
          0 ->
            send(test_pid, {:ordered_blocked, 0, self()})
            receive do: (:release -> 0)

          1 ->
            send(test_pid, {:ordered_blocked, 1, self()})
            receive do: (:explode -> raise("later fatal"))

          2 ->
            send(test_pid, {:ordered_blocked, 2, self()})
            receive do: (:release -> 2)

          item ->
            send(test_pid, {:unexpected_post_fatal_start, item})
            item
        end)
      end)

    workers =
      for _index <- 0..2, into: %{} do
        assert_receive {:ordered_blocked, item, worker}, @receive_timeout
        {item, worker}
      end

    fatal_worker = Map.fetch!(workers, 1)
    fatal_ref = Process.monitor(fatal_worker)
    send(fatal_worker, :explode)
    assert_receive {:DOWN, ^fatal_ref, :process, ^fatal_worker, :normal}, @receive_timeout
    send(Map.fetch!(workers, 2), :release)
    refute_receive {:unexpected_post_fatal_start, _item}, 100

    send(Map.fetch!(workers, 0), :release)

    assert {:exit, {%RuntimeError{message: "later fatal"}, _stacktrace}} =
             Task.yield(task, @receive_timeout)

    refute_received {:unexpected_post_fatal_start, _item}
  end

  test "hard timeout kills the supervised branch" do
    test_pid = self()

    assert_raise RuntimeError, "concurrent workflow branch exceeded 50 ms", fn ->
      Concurrent.run([:work], 1, 50, fn _item ->
        send(test_pid, {:blocked, self()})
        receive do: (:never -> :ok)
      end)
    end

    assert_received {:blocked, worker}
    ref = Process.monitor(worker)
    assert_receive {:DOWN, ^ref, :process, ^worker, _reason}, @receive_timeout
  end

  test "killing the run owner kills in-flight branch work" do
    test_pid = self()

    {:ok, owner} =
      Task.Supervisor.start_child(Workflow.TaskSupervisor, fn ->
        Concurrent.run(1..8, 1, 5_000, fn item ->
          send(test_pid, {:blocked, item, self()})
          receive do: (:never -> send(test_pid, :late_effect))
        end)
      end)

    assert_receive {:blocked, _item, worker}, @receive_timeout
    refute_receive {:blocked, _item, _worker}, 50
    owner_ref = Process.monitor(owner)
    worker_ref = Process.monitor(worker)

    Process.exit(owner, :kill)

    assert_receive {:DOWN, ^owner_ref, :process, ^owner, :killed}, @receive_timeout
    assert_receive {:DOWN, ^worker_ref, :process, ^worker, _reason}, @receive_timeout
    refute_receive {:blocked, _item, _worker}, 100
    refute_receive :late_effect, 100
  end

  defp receive_started do
    assert_receive {:started, item, pid}, @receive_timeout
    {item, pid}
  end

  defp receive_wide_started do
    assert_receive {:wide_started, item, pid}, @receive_timeout
    {item, pid}
  end
end
