defmodule Workflow.ApplicationSupervisionTest do
  use ExUnit.Case, async: false

  alias Workflow.Journal
  alias Workflow.Provider.Codex.AppServer
  alias Workflow.Run
  alias Workflow.Scheduler
  alias Workflow.Test.GateProvider
  alias Workflow.Web.Endpoint

  @receive_timeout 2_000

  defmodule GatedRun do
    @moduledoc false

    def tree do
      Workflow.Test.tree!(
        "supervision-gated-run",
        quote do
          agent("hold")
          return(:ok)
        end,
        __ENV__
      )
    end
  end

  @tag :capture_log
  test "an app-server crash leaves an unrelated writer and endpoint alive" do
    run_id = "supervision_isolation_#{System.unique_integer([:positive])}"

    assert {:ok, ^run_id, writer} =
             Run.start(GatedRun.tree(), run_id: run_id, provider: {GateProvider, sink: self()})

    assert_receive {:agent_called, "hold"}, @receive_timeout
    assert_receive {:at_agent, ^writer}, @receive_timeout

    on_exit(fn ->
      if Process.alive?(writer), do: Process.exit(writer, :kill)
    end)

    stable =
      pids!([
        Workflow.RuntimeSupervisor,
        Workflow.TaskSupervisor,
        Workflow.Run.Supervisor,
        Endpoint
      ])

    old_app_server = pid!(AppServer)
    app_server_monitor = Process.monitor(old_app_server)
    writer_monitor = Process.monitor(writer)

    Process.exit(old_app_server, :kill)

    assert_receive {:DOWN, ^app_server_monitor, :process, ^old_app_server, :killed}, @receive_timeout
    refute await_replacement(AppServer, old_app_server) == old_app_server

    assert pids!(Map.keys(stable)) == stable
    assert Process.alive?(writer)
    refute_receive {:DOWN, ^writer_monitor, :process, ^writer, _reason}, 100

    assert :ok = GateProvider.release(writer)
    assert_receive {:DOWN, ^writer_monitor, :process, ^writer, :normal}, @receive_timeout
  end

  test "the shared task supervisor stays upstream of its runtime dependants" do
    root_pids = child_pids(Workflow.Supervisor)
    runtime_pids = child_pids(Workflow.RuntimeSupervisor)

    task_supervisor = pid!(Workflow.TaskSupervisor)

    assert task_supervisor in root_pids
    assert pid!(Workflow.RuntimeSupervisor) in root_pids
    refute task_supervisor in runtime_pids

    assert pid!(AppServer) in runtime_pids
    assert pid!(Workflow.Run.Supervisor) in runtime_pids
    assert pid!(Endpoint) in runtime_pids
  end

  test "active run admission is globally bounded without journaling rejected runs" do
    started =
      for index <- 1..Run.max_active_runs() do
        run_id = "supervision_capacity_#{index}_#{System.unique_integer([:positive])}"

        assert {:ok, ^run_id, writer} =
                 Run.start(GatedRun.tree(), run_id: run_id, provider: {GateProvider, sink: self()})

        assert_receive {:agent_called, "hold"}, @receive_timeout
        assert_receive {:at_agent, ^writer}, @receive_timeout
        {run_id, writer}
      end

    on_exit(fn ->
      Enum.each(started, fn {_run_id, writer} ->
        if Process.alive?(writer), do: Process.exit(writer, :kill)
      end)
    end)

    rejected_id = "supervision_capacity_rejected_#{System.unique_integer([:positive])}"

    assert {:error, {:capacity_exceeded, max_active_runs}} =
             Run.start(GatedRun.tree(),
               run_id: rejected_id,
               provider: {GateProvider, sink: self()}
             )

    assert max_active_runs == Run.max_active_runs()
    refute Journal.run_exists?(rejected_id)

    script_path =
      Path.join(
        System.tmp_dir!(),
        "codex_loops_capacity_#{System.unique_integer([:positive])}.exs"
      )

    File.write!(script_path, "workflow \"capacity\" do\n  return :ok\nend\n")
    on_exit(fn -> File.rm(script_path) end)

    scheduler_rejected_id =
      "supervision_scheduler_capacity_#{System.unique_integer([:positive])}"

    assert {:error,
            %Workflow.Scheduler.Error{
              status: 503,
              code: "scheduler.run.capacity_exceeded",
              details: %{max_active_runs: ^max_active_runs}
            }} =
             Scheduler.start_run(%{
               "script_path" => script_path,
               "run_id" => scheduler_rejected_id,
               "provider" => "mock"
             })

    refute Journal.run_exists?(scheduler_rejected_id)

    Enum.each(started, fn {_run_id, writer} -> GateProvider.release(writer) end)
  end

  defp pid!(name) do
    Process.whereis(name) || flunk("#{inspect(name)} is not running")
  end

  defp pids!(names), do: Map.new(names, &{&1, pid!(&1)})

  defp await_replacement(name, old, attempts \\ 200)

  defp await_replacement(name, old, 0) do
    flunk("#{inspect(name)} did not replace #{inspect(old)}")
  end

  defp await_replacement(name, old, attempts) do
    case Process.whereis(name) do
      pid when is_pid(pid) and pid != old ->
        pid

      _other ->
        Process.sleep(10)
        await_replacement(name, old, attempts - 1)
    end
  end

  defp child_pids(supervisor) do
    supervisor
    |> Supervisor.which_children()
    |> Enum.map(fn {_id, pid, _type, _modules} -> pid end)
  end
end
