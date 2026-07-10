defmodule Workflow.SchedulerTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Workflow.Journal
  alias Workflow.Provider.Mock
  alias Workflow.Run
  alias Workflow.Scheduler
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
    mod = "SchedulerFixture#{System.unique_integer([:positive])}"

    source = """
    defmodule #{mod} do
      use Workflow
      #{block}
    end
    """

    write_script(source)
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

  defp codex_stub_source do
    """
    #!/bin/sh
    cat >/dev/null
    printf '%s\\n' '{"type":"thread.started","thread_id":"scheduler-stub"}'
    printf '%s\\n' '{"type":"turn.started"}'
    printf '%s\\n' '{"type":"item.completed","item":{"id":"item-1","type":"agent_message","text":"LIVE-MCP-PROOF-OK"}}'
    printf '%s\\n' '{"type":"turn.completed","usage":{"input_tokens":7,"cached_input_tokens":0,"output_tokens":11,"reasoning_output_tokens":0}}'
    """
  end

  defp with_codex_stub(fun) when is_function(fun, 0) do
    dir =
      Path.join(System.tmp_dir!(), "scheduler_codex_stub_#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)

    stub = Path.join(dir, "codex")
    File.write!(stub, codex_stub_source())
    File.chmod!(stub, 0o755)

    previous_path = System.get_env("PATH")
    System.put_env("PATH", dir <> path_separator() <> (previous_path || ""))

    try do
      fun.()
    after
      if previous_path do
        System.put_env("PATH", previous_path)
      else
        System.delete_env("PATH")
      end

      File.rm_rf(dir)
    end
  end

  defp path_separator do
    case :os.type() do
      {:win32, _name} -> ";"
      _other -> ":"
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
      frobnicate "nope"
      return :ok
    end
    """)
  end

  defp syntax_error_workflow do
    dir = Path.join(System.tmp_dir!(), "agent_loops_scheduler_test")
    File.mkdir_p!(dir)
    path = Path.join(dir, "wf_syntax_#{System.unique_integer([:positive])}.exs")

    File.write!(path, """
    defmodule SchedulerSyntaxFixture#{System.unique_integer([:positive])} do
      use Workflow
      workflow "bad" do
        agent "unterminated
        return :ok
      end
    end
    """)

    path
  end

  defp invalid_encoding_workflow do
    write_script(<<255, 254, 253>>, "wf_invalid_encoding")
  end

  defp compile_error_workflow do
    write_workflow("""
    unquote(:outside_quote)

    workflow "compile-bad" do
      return :ok
    end
    """)
  end

  defp top_level_raise_workflow do
    write_workflow("""
    raise "boom"

    workflow "raise-bad" do
      return :ok
    end
    """)
  end

  defp outer_top_level_raise_workflow do
    mod = "SchedulerOuterRaiseFixture#{System.unique_integer([:positive])}"

    write_script(
      """
      raise "outer boom"

      defmodule #{mod} do
        use Workflow

        workflow "outer-raise-bad" do
          return :ok
        end
      end
      """,
      "wf_outer_raise"
    )
  end

  defp no_use_workflow do
    mod = "SchedulerNoUseFixture#{System.unique_integer([:positive])}"

    write_script(
      """
      defmodule #{mod} do
        workflow "no-use" do
          return :ok
        end
      end
      """,
      "wf_no_use"
    )
  end

  defp workflow_before_use_workflow do
    mod = "SchedulerUseAfterFixture#{System.unique_integer([:positive])}"

    write_script(
      """
      defmodule #{mod} do
        workflow "use-after" do
          return :ok
        end

        use Workflow
      end
      """,
      "wf_use_after"
    )
  end

  defp dynamic_module_header_workflow do
    write_script(
      """
      defmodule (raise "module name boom") do
        use Workflow

        workflow "dynamic-module" do
          return :ok
        end
      end
      """,
      "wf_dynamic_module"
    )
  end

  defp schema_after_workflow do
    suffix = System.unique_integer([:positive])
    schema = "SchedulerLateSchema#{suffix}"
    mod = "SchedulerLateSchemaFixture#{suffix}"

    write_script(
      """
      import Workflow.Schema.DSL

      defmodule #{mod} do
        use Workflow

        workflow "schema-after" do
          agent "summarize", schema: #{schema}
          return :ok
        end
      end

      schema #{schema} do
        string :summary
      end
      """,
      "wf_schema_after"
    )
  end

  defp schema_redefinition_workflow do
    mod = "SchedulerSchemaRedefinitionFixture#{System.unique_integer([:positive])}"

    write_script(
      """
      import Workflow.Schema.DSL

      schema Workflow.Scheduler do
        string :summary
      end

      defmodule #{mod} do
        use Workflow

        workflow "schema-redefinition" do
          agent "summarize", schema: Workflow.Scheduler
          return :ok
        end
      end
      """,
      "wf_schema_redefinition"
    )
  end

  defp return_schema_keyword_workflow do
    suffix = System.unique_integer([:positive])
    schema = "SchedulerReturnSchema#{suffix}"
    mod = "SchedulerReturnSchemaFixture#{suffix}"

    path =
      write_script(
        """
        import Workflow.Schema.DSL

        schema #{schema} do
          string :summary
        end

        defmodule #{mod} do
          use Workflow

          workflow "schema-return-keyword" do
            return [schema: #{schema}]
          end
        end
        """,
        "wf_schema_return_keyword"
      )

    {path, String.to_atom(schema)}
  end

  defp schema_backed_workflow do
    suffix = System.unique_integer([:positive])
    schema = "SchedulerLocalSchema#{suffix}"
    mod = "SchedulerSchemaFixture#{suffix}"

    write_script(
      """
      import Workflow.Schema.DSL

      schema #{schema} do
        string :summary
      end

      defmodule #{mod} do
        use Workflow

        workflow "schema-backed" do
          agent "summarize", schema: #{schema}
          return :ok
        end
      end
      """,
      "wf_schema"
    )
  end

  defp fake_workflow_reflection do
    mod = "SchedulerFakeFixture#{System.unique_integer([:positive])}"

    source = """
    defmodule #{mod} do
      use Workflow
      def __workflow__(:tree), do: %Workflow.Tree{name: "fake", nodes: []}
    end
    """

    write_script(source, "wf_fake")
  end

  defp forged_workflow_marker do
    mod = "SchedulerForgedFixture#{System.unique_integer([:positive])}"

    source = """
    defmodule #{mod} do
      use Workflow
      def __workflow__(:source), do: :workflow_dsl
      def __workflow__(:tree), do: %Workflow.Tree{name: "forged", nodes: []}
    end
    """

    write_script(source, "wf_forged")
  end

  defp self_registered_fake_workflow do
    mod = "SchedulerSelfRegisteredFixture#{System.unique_integer([:positive])}"

    source = """
    defmodule #{mod} do
      use Workflow
      Workflow.Script.register_compiled_workflow(__ENV__.file, __MODULE__, make_ref())
      def __workflow__(:tree), do: %Workflow.Tree{name: "self-registered", nodes: []}
    end
    """

    write_script(source, "wf_self_registered")
  end

  test "health reports the supervised runtime boundary dependencies" do
    assert {:ok, health} = Scheduler.health()

    assert health.status == :ok
    assert health.version == Workflow.PackageVersion.version()

    assert health.checks == %{
             otp_app: :available,
             journal: :available,
             pubsub: :available,
             endpoint: :available
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
    assert projection.event_count == 5
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

    assert Enum.map(events, & &1.seq) == [0, 1, 2, 3, 4]

    assert Enum.map(events, & &1.type) == [
             "run_started",
             "phase_entered",
             "log_emitted",
             "agent_committed",
             "run_completed"
           ]

    assert [
             %{seq: 0, type: "run_started"},
             %{seq: 1, type: "phase_entered", address: [0]},
             %{seq: 2, type: "log_emitted", address: [1]},
             %{seq: 3, type: "agent_committed", address: [2]},
             %{seq: 4, type: "run_completed"}
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

    assert completed_action == %{
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

    assert resume_action == %{
             action: :resume,
             label: "Resume",
             enabled: true,
             reason: "The writer is stopped before a terminal event.",
             method: "post",
             href: "/api/runs/#{running_id}/resume"
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

    assert {:ok, ^id, writer} =
             Run.start(tree,
               run_id: id,
               provider: {GateProvider, sink: self()}
             )

    assert_receive {:agent_called, "ship it"}
    assert_receive {:at_agent, ^writer}

    assert %Workflow.Event{payload: %{script_path: nil}} =
             Enum.find(Journal.fold(id), &(&1.type == :run_started))

    kill_and_await(id, writer)

    assert {:ok, %{state: :running, lifecycle_action: action}} = Scheduler.get_run(id)

    assert action == %{
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
    assert error.details.reason =~ "unknown combinator `frobnicate`"

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
  test "resume through scheduler does not repeat already committed agent effects" do
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
    wait_for_projection(id)

    assert id
           |> Journal.fold()
           |> Enum.filter(&(&1.type == :agent_committed))
           |> Enum.map(& &1.payload.address) == [[0], [1]]

    assert {:ok, %{state: :completed, event_count: event_count}} = Scheduler.get_run(id)
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

  test "starts a codex-provider run through the scheduler context with a hermetic CLI on PATH" do
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

  test "validates a same-file schema-backed workflow script through the scheduler context" do
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
    assert error.details.reason =~ "unknown combinator `frobnicate`"
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
    parent = self()

    capture_io(:stderr, fn ->
      send(parent, {:validation_result, Scheduler.validate_workflow(%{"script_path" => path})})
    end)

    assert_received {:validation_result, {:error, %Scheduler.Error{} = error}}

    assert error.status == 422
    assert error.code == "scheduler.validation.compile"
    assert error.details.path == path
    assert error.details.type == :compile
    assert error.details.reason =~ "cannot compile module"
  end

  test "top-level compile-time exceptions return a typed scheduler validation error" do
    path = top_level_raise_workflow()

    assert {:error, %Scheduler.Error{} = error} =
             Scheduler.validate_workflow(%{"script_path" => path})

    assert error.status == 422
    assert error.code == "scheduler.validation.compile"
    assert error.details.path == path
    assert error.details.type == :compile
    assert error.details.reason =~ "boom"
  end

  test "outer top-level script forms return a typed scheduler validation error" do
    path = outer_top_level_raise_workflow()

    assert {:error, %Scheduler.Error{} = error} =
             Scheduler.validate_workflow(%{"script_path" => path})

    assert error.status == 422
    assert error.code == "scheduler.validation.compile"
    assert error.details.path == path
    assert error.details.type == :compile
    assert error.details.reason =~ "outer boom"
  end

  test "workflow declarations without use Workflow return a typed scheduler validation error" do
    path = no_use_workflow()

    assert {:error, %Scheduler.Error{} = error} =
             Scheduler.validate_workflow(%{"script_path" => path})

    assert error.status == 422
    assert error.code == "scheduler.validation.compile"
    assert error.details.path == path
    assert error.details.type == :compile
    assert error.details.reason =~ "must `use Workflow`"
  end

  test "workflow declarations before use Workflow return a typed scheduler validation error" do
    path = workflow_before_use_workflow()

    assert {:error, %Scheduler.Error{} = error} =
             Scheduler.validate_workflow(%{"script_path" => path})

    assert error.status == 422
    assert error.code == "scheduler.validation.compile"
    assert error.details.path == path
    assert error.details.type == :compile
    assert error.details.reason =~ "must appear after `use Workflow`"
  end

  test "dynamic workflow module headers return a typed scheduler validation error" do
    path = dynamic_module_header_workflow()

    assert {:error, %Scheduler.Error{} = error} =
             Scheduler.validate_workflow(%{"script_path" => path})

    assert error.status == 422
    assert error.code == "scheduler.validation.compile"
    assert error.details.path == path
    assert error.details.type == :compile
    assert error.details.reason =~ "module name must be a literal alias"
  end

  test "same-file schema definitions after workflow modules are rejected" do
    path = schema_after_workflow()

    assert {:error, %Scheduler.Error{} = error} =
             Scheduler.validate_workflow(%{"script_path" => path})

    assert error.status == 422
    assert error.code == "scheduler.validation.compile"
    assert error.details.path == path
    assert error.details.type == :compile
    assert error.details.reason =~ "schema definitions must appear before the workflow module"
  end

  test "same-file schemas cannot redefine existing scheduler modules" do
    path = schema_redefinition_workflow()
    assert Code.ensure_loaded?(Scheduler)
    assert function_exported?(Scheduler, :validate_workflow, 1)

    assert {:error, %Scheduler.Error{} = error} =
             Scheduler.validate_workflow(%{"script_path" => path})

    assert error.status == 422
    assert error.code == "scheduler.validation.compile"
    assert error.details.path == path
    assert error.details.type == :compile
    assert error.details.reason =~ "would redefine an existing module"
    assert Code.ensure_loaded?(Scheduler)
    assert function_exported?(Scheduler, :validate_workflow, 1)
    assert {:ok, _health} = Scheduler.health()
  end

  test "same-file schema inlining is scoped to agent options" do
    {path, schema_atom} = return_schema_keyword_workflow()

    assert {:ok, %Workflow.Tree{nodes: [%Workflow.Node.Return{value: value}]}} =
             Script.load_tree(path)

    assert [{:schema, {:__aliases__, _meta, [^schema_atom]}}] = value

    assert {:ok, validation} = Scheduler.validate_workflow(%{"script_path" => path})
    assert validation.workflow_name == "schema-return-keyword"
    assert validation.node_count == 1
  end

  test "hand-written workflow reflection does not bypass the compile gate" do
    path = fake_workflow_reflection()

    assert {:error, %Scheduler.Error{} = error} =
             Scheduler.validate_workflow(%{"script_path" => path})

    assert error.status == 422
    assert error.code == "scheduler.validation.compile"
    assert error.details.path == path
    assert error.details.type == :compile
    assert error.details.reason =~ "unsupported top-level workflow script form"
  end

  test "forged workflow marker does not bypass the compile gate" do
    path = forged_workflow_marker()

    assert {:error, %Scheduler.Error{} = error} =
             Scheduler.validate_workflow(%{"script_path" => path})

    assert error.status == 422
    assert error.code == "scheduler.validation.compile"
    assert error.details.path == path
    assert error.details.type == :compile
    assert error.details.reason =~ "unsupported top-level workflow script form"
  end

  test "self-registered workflow reflection does not bypass the compile gate" do
    path = self_registered_fake_workflow()

    assert {:error, %Scheduler.Error{} = error} =
             Scheduler.validate_workflow(%{"script_path" => path})

    assert error.status == 422
    assert error.code == "scheduler.validation.compile"
    assert error.details.path == path
    assert error.details.type == :compile
    assert error.details.reason =~ "unsupported top-level workflow script form"
  end
end
