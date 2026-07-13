defmodule Workflow.SchedulerTest do
  use ExUnit.Case, async: false

  alias Workflow.IdempotencyKey
  alias Workflow.Journal
  alias Workflow.Provider.Codex.AppServer
  alias Workflow.Provider.Mock
  alias Workflow.Run
  alias Workflow.Scheduler
  alias Workflow.Scheduler.LifecycleAction
  alias Workflow.Script
  alias Workflow.Status
  alias Workflow.Test.GateProvider

  defp write_script(source, prefix \\ "wf") do
    dir = Path.join(System.tmp_dir!(), "agent_loops_scheduler_test")
    File.mkdir_p!(dir)
    path = Path.join(dir, "#{prefix}_#{System.unique_integer([:positive])}.exs")
    File.write!(path, source)
    path
  end

  defp write_workflow(block) do
    write_script(block)
  end

  defp demo_workflow do
    write_workflow(~S"""
    workflow "scheduler-demo" do
      phase "draft"
      log "ready"
      agent "ship it"
      return :ok
    end
    """)
  end

  defp with_codex_stub(fun) when is_function(fun, 0) do
    python = System.find_executable("python3")
    stub = Path.expand("support/codex_app_server_stub.py", __DIR__ <> "/..")

    previous_codex_command = Application.get_env(:codex_loops, :codex_command)
    AppServer.reset()
    Application.put_env(:codex_loops, :codex_command, {python, [stub, "live_proof"]})

    try do
      fun.()
    after
      AppServer.reset()

      if previous_codex_command do
        Application.put_env(:codex_loops, :codex_command, previous_codex_command)
      else
        Application.delete_env(:codex_loops, :codex_command)
      end
    end
  end

  defp two_agent_workflow do
    write_workflow(~S"""
    workflow "scheduler-two-agents" do
      agent "first"
      agent "second"
      return :ok
    end
    """)
  end

  defp run_id(prefix), do: "#{prefix}_#{System.unique_integer([:positive])}"

  defp await_lease_released(run_id, tries \\ 200) do
    cond do
      Registry.lookup(Workflow.Run.Registry, run_id) == [] ->
        :ok

      tries == 0 ->
        flunk("lease for #{run_id} was never released")

      true ->
        Process.sleep(5)
        await_lease_released(run_id, tries - 1)
    end
  end

  defp kill_and_await(run_id, pid) do
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
    await_lease_released(run_id)
  end

  defp wait_for_projection(id, state \\ :completed, attempts \\ 50)

  defp wait_for_projection(id, state, 0) do
    flunk("expected run #{id} to reach #{inspect(state)}, got #{inspect(Scheduler.get_run(id))}")
  end

  defp wait_for_projection(id, state, attempts) do
    case Scheduler.get_run(id) do
      {:ok, projection} when projection.state == state ->
        projection

      _other ->
        Process.sleep(10)
        wait_for_projection(id, state, attempts - 1)
    end
  end

  defp bad_workflow do
    write_workflow(~S"""
    workflow "scheduler-bad" do
      raise "nope"
      return :ok
    end
    """)
  end

  defp syntax_error_workflow do
    dir = Path.join(System.tmp_dir!(), "agent_loops_scheduler_test")
    File.mkdir_p!(dir)
    path = Path.join(dir, "wf_syntax_#{System.unique_integer([:positive])}.exs")

    File.write!(path, """
    workflow "bad" do
      agent "unterminated
      return :ok
    end
    """)

    path
  end

  defp invalid_encoding_workflow do
    write_script(<<255, 254, 253>>, "wf_invalid_encoding")
  end

  defp compile_error_workflow do
    write_workflow(~S"""
    workflow "compile-bad" do
      System.system_time()
      return :ok
    end
    """)
  end

  defp schema_backed_workflow do
    write_script(
      ~S"""
      workflow "schema-backed" do
        agent "summarize",
          schema: %{
            "type" => "object",
            "properties" => %{"summary" => %{"type" => "string"}},
            "required" => ["summary"]
          }

        return :ok
      end
      """,
      "wf_schema"
    )
  end

  test "health reports the supervised runtime boundary dependencies" do
    assert {:ok, health} = Scheduler.health()

    assert health.status == :ok
    assert health.version == Workflow.PackageVersion.version()

    assert health.checks == %{
             otp_app: :available,
             journal: :available,
             pubsub: :available
           }
  end

  test "starts a mock-provider run with an explicit run id through the scheduler context" do
    path = demo_workflow()
    id = run_id("scheduler_explicit")

    assert {:ok, start} =
             Scheduler.start_run(%{
               "script_path" => path,
               "run_id" => id,
               "provider" => "mock",
               "budget" => 0
             })

    assert start.run_id == id
    assert start.state == :accepted
    assert start.ui_path == "/runs/#{id}"
    assert start.ui_url == "/runs/#{id}"

    projection = wait_for_projection(id)

    assert projection.run_id == id
    assert projection.state == :completed
    assert projection.workflow_name == "scheduler-demo"
    assert projection.phase == "draft"
    assert projection.logs == ["ready"]
    assert projection.agent_count == 1
    assert projection.event_count == 6
    assert projection.usage.total_tokens == 0
    assert projection.result == :ok
    assert projection.failure == nil
    assert projection.ui_path == "/runs/#{id}"
    assert projection.ui_url == "/runs/#{id}"
  end

  test "get_run_events returns ordered scheduler-owned event projections" do
    path = demo_workflow()
    id = run_id("scheduler_events")

    assert {:ok, start} =
             Scheduler.start_run(%{
               "script_path" => path,
               "run_id" => id,
               "provider" => "mock"
             })

    assert start.run_id == id
    wait_for_projection(id)

    assert {:ok, %{run_id: ^id, events: events}} = Scheduler.get_run_events(id)

    assert Enum.map(events, & &1.seq) == [0, 1, 2, 3, 4, 5]

    assert Enum.map(events, & &1.type) == [
             "run_started",
             "phase_entered",
             "log_emitted",
             "agent_started",
             "agent_committed",
             "run_completed"
           ]

    assert [
             %{seq: 0, type: "run_started"},
             %{seq: 1, type: "phase_entered", address: [0]},
             %{seq: 2, type: "log_emitted", address: [1]},
             %{seq: 3, type: "agent_started", address: [2]},
             %{seq: 4, type: "agent_committed", address: [2]},
             %{seq: 5, type: "run_completed"}
           ] = events
  end

  test "resume recovers a journaled script path and does not duplicate completed run events" do
    path = demo_workflow()
    id = run_id("scheduler_resume_completed")

    assert {:ok, _start} =
             Scheduler.start_run(%{
               "script_path" => path,
               "run_id" => id,
               "provider" => "mock"
             })

    projection = wait_for_projection(id)
    before_events = Journal.fold(id)
    before_types = Enum.map(before_events, & &1.type)

    assert projection.event_count == length(before_events)

    assert {:ok, resume} = Scheduler.resume_run(id)
    assert resume.run_id == id
    assert resume.state == :accepted
    assert resume.ui_path == "/runs/#{id}"

    await_lease_released(id)

    after_events = Journal.fold(id)
    assert Enum.map(after_events, & &1.type) == before_types

    assert {:ok, %{state: :completed, event_count: event_count}} = Scheduler.get_run(id)
    assert event_count == length(after_events)
  end

  @tag :capture_log
  test "run projection lifecycle action is for monitoring affordances, not every accepted command" do
    path = demo_workflow()
    completed_id = run_id("scheduler_lifecycle_completed")

    assert {:ok, _start} =
             Scheduler.start_run(%{
               "script_path" => path,
               "run_id" => completed_id,
               "provider" => "mock"
             })

    assert %{lifecycle_action: completed_action} = wait_for_projection(completed_id)

    assert completed_action == %LifecycleAction{
             action: :none,
             label: "Finished",
             enabled: false,
             reason: "Run completed successfully.",
             method: nil,
             href: nil
           }

    assert {:ok, %{run_id: ^completed_id, state: :accepted}} = Scheduler.resume_run(completed_id)
    await_lease_released(completed_id)
    assert %{lifecycle_action: ^completed_action} = wait_for_projection(completed_id)

    running_id = run_id("scheduler_lifecycle_running")
    {:ok, tree} = Script.load_tree(path)

    assert {:ok, ^running_id, writer} =
             Run.start(tree,
               run_id: running_id,
               provider: {GateProvider, sink: self()},
               script_path: Path.expand(path)
             )

    assert_receive {:agent_called, "ship it"}
    assert_receive {:at_agent, ^writer}

    assert {:ok,
            %{
              state: :running,
              lifecycle_action: %{
                action: :pause_unavailable,
                label: "Pause unavailable",
                enabled: false,
                method: nil,
                href: nil
              }
            }} = Scheduler.get_run(running_id)

    kill_and_await(running_id, writer)

    assert {:ok, %{state: :running, lifecycle_action: resume_action}} =
             Scheduler.get_run(running_id)

    assert resume_action == %LifecycleAction{
             action: :resume_unavailable,
             label: "Resume unavailable",
             enabled: false,
             reason: "A provider attempt has an unknown outcome; replay could duplicate a paid effect.",
             method: nil,
             href: nil
           }
  end

  @tag :capture_log
  test "get_run_snapshot returns status and run projection from one scheduler read" do
    path = demo_workflow()
    id = run_id("scheduler_snapshot")

    assert {:ok, _start} =
             Scheduler.start_run(%{
               "script_path" => path,
               "run_id" => id,
               "provider" => "mock"
             })

    completed_projection = wait_for_projection(id)

    assert {:ok, %{status: %Status{} = status, run_projection: snapshot_projection}} =
             Scheduler.get_run_snapshot(id)

    assert status.run_id == id
    assert status.state == :completed
    assert snapshot_projection.run_id == id
    assert snapshot_projection.state == status.state
    assert snapshot_projection.event_count == status.event_count
    assert snapshot_projection.lifecycle_action == completed_projection.lifecycle_action
  end

  @tag :capture_log
  test "run projection renders resume unavailable when incomplete run has no script path" do
    path = demo_workflow()
    id = run_id("scheduler_lifecycle_missing_script")
    {:ok, tree} = Script.load_tree(path)

    assert :ok = Journal.register_run(id)
    assert {:ok, %{seq: 0}} = Journal.append_next(id, Workflow.Event.run_started(tree))

    assert %Workflow.Event{payload: %{script_path: nil}} =
             Enum.find(Journal.fold(id), &(&1.type == :run_started))

    assert {:ok, %{state: :running, lifecycle_action: action}} = Scheduler.get_run(id)

    assert action == %LifecycleAction{
             action: :resume_unavailable,
             label: "Resume unavailable",
             enabled: false,
             reason: "No journaled script path is available.",
             method: nil,
             href: nil
           }
  end

  test "resume accepts an explicit script path when the journal has no script path" do
    path = demo_workflow()
    id = run_id("scheduler_resume_explicit")
    {:ok, tree} = Script.load_tree(path)

    assert {:ok, ^id} =
             Run.run(tree, run_id: id, provider: {Mock, []})

    assert %Workflow.Event{payload: %{script_path: nil}} =
             Enum.find(Journal.fold(id), &(&1.type == :run_started))

    before_count = id |> Journal.fold() |> length()

    assert {:ok, resume} =
             Scheduler.resume_run(id, %{"script_path" => path, "provider" => "mock"})

    assert resume.run_id == id
    await_lease_released(id)

    assert id |> Journal.fold() |> length() == before_count
    assert {:ok, %{state: :completed}} = Scheduler.get_run(id)
  end

  test "resume returns typed errors for unknown runs and missing recoverable scripts" do
    unknown = run_id("scheduler_resume_unknown")

    assert {:error, %Scheduler.Error{} = error} = Scheduler.resume_run(unknown)
    assert error.status == 404
    assert error.code == "scheduler.run.not_found"
    assert error.details == %{run_id: unknown}

    path = demo_workflow()
    id = run_id("scheduler_resume_missing_script")
    {:ok, tree} = Script.load_tree(path)

    assert {:ok, ^id} =
             Run.run(tree, run_id: id, provider: {Mock, []})

    assert {:error, %Scheduler.Error{} = error} = Scheduler.resume_run(id)
    assert error.status == 400
    assert error.code == "scheduler.validation.missing_script_path"
    assert error.details == %{field: "script_path"}
  end

  test "resume validates explicit script paths and provider inputs" do
    path = demo_workflow()
    id = run_id("scheduler_resume_validation")
    {:ok, tree} = Script.load_tree(path)

    assert {:ok, ^id} =
             Run.run(tree, run_id: id, provider: {Mock, []})

    assert {:error, %Scheduler.Error{} = error} =
             Scheduler.resume_run(id, %{"script_path" => bad_workflow(), "provider" => "mock"})

    assert error.status == 422
    assert error.code == "scheduler.validation.workflow_dsl"
    assert error.details.reason =~ "unknown combinator `raise`"

    assert {:error, %Scheduler.Error{} = error} =
             Scheduler.resume_run(id, %{"script_path" => path, "provider" => "bogus"})

    assert error.status == 400
    assert error.code == "scheduler.run.invalid_provider"
    assert error.details == %{field: "provider", supported: ["mock", "codex"]}
  end

  @tag :capture_log
  test "resume returns a typed already-running error when a live writer holds the lease" do
    path = demo_workflow()
    id = run_id("scheduler_resume_running")
    {:ok, tree} = Script.load_tree(path)

    assert {:ok, ^id, writer} =
             Run.start(tree,
               run_id: id,
               provider: {GateProvider, sink: self()},
               script_path: Path.expand(path)
             )

    assert_receive {:agent_called, "ship it"}
    assert_receive {:at_agent, ^writer}

    assert {:error, %Scheduler.Error{} = error} = Scheduler.resume_run(id)
    assert error.status == 409
    assert error.code == "scheduler.run.already_running"
    assert error.details == %{run_id: id}

    send(writer, :proceed)
    await_lease_released(id)
  end

  @tag :capture_log
  test "resume through scheduler fails closed without repeating an unknown effect" do
    path = two_agent_workflow()
    id = run_id("scheduler_resume_once")
    {:ok, tree} = Script.load_tree(path)

    assert {:ok, ^id, writer} =
             Run.start(tree,
               run_id: id,
               provider: {GateProvider, sink: self(), gate_on: "second"},
               script_path: Path.expand(path)
             )

    assert_receive {:agent_called, "first"}
    assert_receive {:agent_called, "second"}
    assert_receive {:at_agent, ^writer}

    assert [%{payload: %{address: [0]}}] =
             Enum.filter(Journal.fold(id), &(&1.type == :agent_committed))

    kill_and_await(id, writer)

    assert {:ok, %{run_id: ^id, state: :accepted}} = Scheduler.resume_run(id)
    projection = wait_for_projection(id, :failed)

    assert id
           |> Journal.fold()
           |> Enum.filter(&(&1.type == :agent_committed))
           |> Enum.map(& &1.payload.address) == [[0]]

    assert projection.failure.reason ==
             {:outcome_unknown, %IdempotencyKey{run_id: id, node_path: [1], iteration: 0, attempt: 0}}

    assert {:ok, %{state: :failed, event_count: event_count}} = Scheduler.get_run(id)
    assert event_count == length(Journal.fold(id))
  end

  test "starts a mock-provider run with a generated run id" do
    path = demo_workflow()

    assert {:ok, start} =
             Scheduler.start_run(%{
               script_path: path,
               provider: :mock
             })

    assert start.run_id =~ ~r/^run_[0-9a-f]+$/
    assert start.state == :accepted
    assert start.ui_path == "/runs/#{start.run_id}"

    projection = wait_for_projection(start.run_id)
    assert projection.workflow_name == "scheduler-demo"
  end

  test "starts a codex-provider run through the scheduler context with an injected hermetic CLI" do
    with_codex_stub(fn ->
      path = demo_workflow()
      id = run_id("scheduler_codex")

      assert {:ok, start} =
               Scheduler.start_run(%{
                 "script_path" => path,
                 "run_id" => id,
                 "provider" => "codex"
               })

      assert start.run_id == id
      assert start.state == :accepted

      projection = wait_for_projection(id)
      assert projection.workflow_name == "scheduler-demo"
      assert projection.usage.total_tokens == 18
    end)
  end

  test "start returns a typed error for missing workflow scripts" do
    path =
      Path.join(
        System.tmp_dir!(),
        "agent_loops_missing_start_#{System.unique_integer([:positive])}.exs"
      )

    assert {:error, %Scheduler.Error{} = error} =
             Scheduler.start_run(%{"script_path" => path, "provider" => "mock"})

    assert error.status == 404
    assert error.code == "scheduler.validation.script_not_found"
    assert error.details.path == path
  end

  test "start rejects unsupported providers with supported-provider details" do
    path = demo_workflow()

    assert {:error, %Scheduler.Error{} = error} =
             Scheduler.start_run(%{"script_path" => path, "provider" => "bogus"})

    assert error.status == 400
    assert error.code == "scheduler.run.invalid_provider"
    assert error.details == %{field: "provider", supported: ["mock", "codex"]}
  end

  test "start rejects invalid budgets as typed input errors" do
    path = demo_workflow()

    assert {:error, %Scheduler.Error{} = error} =
             Scheduler.start_run(%{"script_path" => path, "provider" => "mock", "budget" => -1})

    assert error.status == 400
    assert error.code == "scheduler.run.invalid_budget"
    assert error.details == %{field: "budget", expected: "non_negative_integer"}
  end

  test "start rejects run ids that cannot round-trip through run routes" do
    path = demo_workflow()

    assert {:error, %Scheduler.Error{} = error} =
             Scheduler.start_run(%{
               "script_path" => path,
               "provider" => "mock",
               "run_id" => "foo/bar"
             })

    assert error.status == 400
    assert error.code == "scheduler.run.invalid_run_id"
    assert error.details == %{field: "run_id", expected: "route_safe_non_empty_string"}
    refute "foo/bar" in Journal.run_ids()
  end

  test "get_run returns a typed error for unknown run ids" do
    id = run_id("scheduler_unknown")

    assert {:error, %Scheduler.Error{} = error} = Scheduler.get_run(id)

    assert error.status == 404
    assert error.code == "scheduler.run.not_found"
    assert error.details == %{run_id: id}
  end

  test "already-running run ids map to a typed 409 scheduler error" do
    path = demo_workflow()
    id = run_id("scheduler_running")
    {:ok, tree} = Script.load_tree(path)

    assert {:ok, ^id, writer} =
             Run.start(tree,
               run_id: id,
               provider: {GateProvider, sink: self()},
               script_path: Path.expand(path)
             )

    assert_receive {:agent_called, "ship it"}
    assert_receive {:at_agent, turn}

    assert {:error, %Scheduler.Error{} = error} =
             Scheduler.start_run(%{"script_path" => path, "run_id" => id, "provider" => "mock"})

    assert error.status == 409
    assert error.code == "scheduler.run.already_running"
    assert error.details == %{run_id: id}

    ref = Process.monitor(writer)
    send(turn, :proceed)
    assert_receive {:DOWN, ^ref, :process, ^writer, :normal}
  end

  test "validates an existing workflow script through the scheduler context" do
    path = demo_workflow()
    run_ids = Journal.run_ids()

    assert {:ok, validation} = Scheduler.validate_workflow(%{"script_path" => path})

    assert validation.valid == true
    assert validation.workflow_name == "scheduler-demo"
    assert validation.node_count == 4
    assert validation.script == %{path: path}
    assert Journal.run_ids() == run_ids
  end

  test "validates a literal-schema workflow script through the scheduler context" do
    path = schema_backed_workflow()
    run_ids = Journal.run_ids()

    assert {:ok, validation} = Scheduler.validate_workflow(%{"script_path" => path})

    assert validation.valid == true
    assert validation.workflow_name == "schema-backed"
    assert validation.node_count == 2
    assert validation.script == %{path: path}
    assert Journal.run_ids() == run_ids
  end

  test "missing workflow scripts return a typed scheduler validation error" do
    path =
      Path.join(
        System.tmp_dir!(),
        "agent_loops_missing_#{System.unique_integer([:positive])}.exs"
      )

    assert {:error, %Scheduler.Error{} = error} =
             Scheduler.validate_workflow(%{"script_path" => path})

    assert error.status == 404
    assert error.code == "scheduler.validation.script_not_found"
    assert error.message == "workflow script not found: #{path}"

    assert error.details == %{
             path: path,
             reason: "workflow script not found: #{path}",
             type: :script_not_found
           }
  end

  test "malformed workflow DSL returns a typed scheduler validation error" do
    path = bad_workflow()

    assert {:error, %Scheduler.Error{} = error} =
             Scheduler.validate_workflow(%{"script_path" => path})

    assert error.status == 422
    assert error.code == "scheduler.validation.workflow_dsl"
    assert error.message == "Workflow script failed validation."
    assert error.details.path == path
    assert error.details.type == :workflow_dsl
    assert error.details.reason =~ "unknown combinator `raise`"
  end

  test "syntax errors return a typed scheduler validation error" do
    path = syntax_error_workflow()

    assert {:error, %Scheduler.Error{} = error} =
             Scheduler.validate_workflow(%{"script_path" => path})

    assert error.status == 422
    assert error.code == "scheduler.validation.syntax"
    assert error.details.path == path
    assert error.details.type == :syntax
    assert error.details.reason =~ "missing terminator"
  end

  test "invalid source encoding returns a typed scheduler validation error" do
    path = invalid_encoding_workflow()

    assert {:error, %Scheduler.Error{} = error} =
             Scheduler.validate_workflow(%{"script_path" => path})

    assert error.status == 422
    assert error.code == "scheduler.validation.syntax"
    assert error.details.path == path
    assert error.details.type == :syntax
    assert error.details.reason =~ "invalid encoding"
  end

  test "ordinary compile errors return a typed scheduler validation error" do
    path = compile_error_workflow()

    assert {:error, %Scheduler.Error{} = error} =
             Scheduler.validate_workflow(%{"script_path" => path})

    assert error.status == 422
    assert error.code == "scheduler.validation.workflow_dsl"
    assert error.details.path == path
    assert error.details.type == :workflow_dsl
    assert error.details.reason =~ "external modules"
  end
end
