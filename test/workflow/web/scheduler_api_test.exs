defmodule Workflow.Web.SchedulerAPITest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO
  import Phoenix.ConnTest
  import Plug.Conn, only: [put_req_header: 3]

  alias Workflow.Journal
  alias Workflow.Provider.Mock
  alias Workflow.Run
  alias Workflow.Script
  alias Workflow.Test.GateProvider

  @endpoint Workflow.Web.Endpoint

  defp write_script(source, prefix \\ "wf") do
    dir = Path.join(System.tmp_dir!(), "agent_loops_scheduler_api_test")
    File.mkdir_p!(dir)
    path = Path.join(dir, "#{prefix}_#{System.unique_integer([:positive])}.exs")
    File.write!(path, source)
    path
  end

  defp write_workflow(block) do
    mod = "SchedulerAPIFixture#{System.unique_integer([:positive])}"

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
    workflow "scheduler-api-demo" do
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
    printf '%s\\n' '{"type":"thread.started","thread_id":"scheduler-api-stub"}'
    printf '%s\\n' '{"type":"turn.started"}'
    printf '%s\\n' '{"type":"item.completed","item":{"id":"item-1","type":"agent_message","text":"LIVE-MCP-PROOF-OK"}}'
    printf '%s\\n' '{"type":"turn.completed","usage":{"input_tokens":7,"cached_input_tokens":0,"output_tokens":11,"reasoning_output_tokens":0}}'
    """
  end

  defp with_codex_stub(fun) when is_function(fun, 0) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "scheduler_api_codex_stub_#{System.unique_integer([:positive])}"
      )

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
    workflow "scheduler-api-two-agents" do
      agent "first"
      agent "second"
      return :ok
    end
    """)
  end

  defp bad_workflow do
    write_workflow(~S"""
    workflow "scheduler-api-bad" do
      frobnicate "nope"
      return :ok
    end
    """)
  end

  defp syntax_error_workflow do
    dir = Path.join(System.tmp_dir!(), "agent_loops_scheduler_api_test")
    File.mkdir_p!(dir)
    path = Path.join(dir, "wf_syntax_#{System.unique_integer([:positive])}.exs")

    File.write!(path, """
    defmodule SchedulerAPISyntaxFixture#{System.unique_integer([:positive])} do
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
    mod = "SchedulerAPIOuterRaiseFixture#{System.unique_integer([:positive])}"

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
    mod = "SchedulerAPINoUseFixture#{System.unique_integer([:positive])}"

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
    mod = "SchedulerAPIUseAfterFixture#{System.unique_integer([:positive])}"

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
    schema = "SchedulerAPILateSchema#{suffix}"
    mod = "SchedulerAPILateSchemaFixture#{suffix}"

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
    mod = "SchedulerAPISchemaRedefinitionFixture#{System.unique_integer([:positive])}"

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

  defp schema_backed_workflow do
    suffix = System.unique_integer([:positive])
    schema = "SchedulerAPILocalSchema#{suffix}"
    mod = "SchedulerAPISchemaFixture#{suffix}"

    write_script(
      """
      import Workflow.Schema.DSL

      schema #{schema} do
        string :summary
      end

      defmodule #{mod} do
        use Workflow

        workflow "schema-backed-api" do
          agent "summarize", schema: #{schema}
          return :ok
        end
      end
      """,
      "wf_schema"
    )
  end

  defp fake_workflow_reflection do
    mod = "SchedulerAPIFakeFixture#{System.unique_integer([:positive])}"

    source = """
    defmodule #{mod} do
      use Workflow
      def __workflow__(:tree), do: %Workflow.Tree{name: "fake", nodes: []}
    end
    """

    write_script(source, "wf_fake")
  end

  defp forged_workflow_marker do
    mod = "SchedulerAPIForgedFixture#{System.unique_integer([:positive])}"

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
    mod = "SchedulerAPISelfRegisteredFixture#{System.unique_integer([:positive])}"

    source = """
    defmodule #{mod} do
      use Workflow
      Workflow.Script.register_compiled_workflow(__ENV__.file, __MODULE__, make_ref())
      def __workflow__(:tree), do: %Workflow.Tree{name: "self-registered", nodes: []}
    end
    """

    write_script(source, "wf_self_registered")
  end

  defp json_conn do
    put_req_header(build_conn(), "accept", "application/json")
  end

  defp post_json(conn, path, body) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(path, Jason.encode!(body))
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

  defp wait_for_api_projection(id, attempts \\ 50)

  defp wait_for_api_projection(id, 0), do: flunk("expected GET /api/runs/#{id} to return a completed projection")

  defp wait_for_api_projection(id, attempts) do
    conn = get(json_conn(), "/api/runs/#{id}")

    case json_response(conn, 200) do
      %{"data" => %{"state" => "completed"} = data} ->
        data

      _other ->
        Process.sleep(10)
        wait_for_api_projection(id, attempts - 1)
    end
  rescue
    ExUnit.AssertionError ->
      Process.sleep(10)
      wait_for_api_projection(id, attempts - 1)
  end

  defp wait_for_api_state(id, state, attempts \\ 50)

  defp wait_for_api_state(id, state, 0), do: flunk("expected GET /api/runs/#{id} to return a #{state} projection")

  defp wait_for_api_state(id, state, attempts) do
    conn = get(json_conn(), "/api/runs/#{id}")

    case json_response(conn, 200) do
      %{"data" => %{"state" => ^state} = data} ->
        data

      _other ->
        Process.sleep(10)
        wait_for_api_state(id, state, attempts - 1)
    end
  rescue
    ExUnit.AssertionError ->
      Process.sleep(10)
      wait_for_api_state(id, state, attempts - 1)
  end

  defp wait_for_api_events(id, attempts \\ 50)

  defp wait_for_api_events(id, attempts) when attempts <= 0,
    do: flunk("expected GET /api/runs/#{id}/events to return completed run events")

  defp wait_for_api_events(id, attempts) do
    conn = get(json_conn(), "/api/runs/#{id}/events")

    case json_response(conn, 200) do
      %{
        "data" => %{
          "runId" => ^id,
          "events" => events
        }
      } = response ->
        if Enum.any?(events, &match?(%{"type" => "run_completed"}, &1)) do
          response
        else
          retry_api_events(id, attempts)
        end

      _other ->
        retry_api_events(id, attempts)
    end
  rescue
    ExUnit.AssertionError ->
      retry_api_events(id, attempts)
  end

  defp retry_api_events(id, attempts) when attempts <= 1, do: wait_for_api_events(id, 0)

  defp retry_api_events(id, attempts) do
    Process.sleep(10)
    wait_for_api_events(id, attempts - 1)
  end

  test "GET /api/health returns a versioned ready response" do
    conn = get(json_conn(), "/api/health")

    assert %{
             "api_version" => "scheduler.v1",
             "data" => %{
               "status" => "ok",
               "version" => version,
               "checks" => %{
                 "otp_app" => "available",
                 "journal" => "available",
                 "pubsub" => "available",
                 "endpoint" => "available"
               }
             }
           } = json_response(conn, 200)

    assert version == Workflow.PackageVersion.version()
  end

  test "POST /api/runs starts a mock-provider run and returns an accepted response" do
    path = demo_workflow()
    id = run_id("scheduler_api_explicit")

    conn = post_json(json_conn(), "/api/runs", %{script_path: path, run_id: id, provider: "mock", budget: 0})

    assert %{
             "api_version" => "scheduler.v1",
             "data" => %{
               "run_id" => ^id,
               "state" => "accepted",
               "ui_path" => "/runs/" <> ^id,
               "ui_url" => "/runs/" <> ^id
             }
           } = json_response(conn, 200)
  end

  test "POST /api/runs can start a codex-provider run with a hermetic CLI on PATH" do
    with_codex_stub(fn ->
      path = demo_workflow()
      id = run_id("scheduler_api_codex")

      conn = post_json(json_conn(), "/api/runs", %{script_path: path, run_id: id, provider: "codex"})

      assert %{
               "api_version" => "scheduler.v1",
               "data" => %{
                 "run_id" => ^id,
                 "state" => "accepted",
                 "ui_path" => "/runs/" <> ^id,
                 "ui_url" => "/runs/" <> ^id
               }
             } = json_response(conn, 200)

      assert %{
               "state" => "completed",
               "usage" => %{
                 "inputTokens" => 7,
                 "outputTokens" => 11,
                 "totalTokens" => 18
               },
               "result" => "ok"
             } = wait_for_api_projection(id)

      refute Map.has_key?(wait_for_api_projection(id), "events")
      refute Map.has_key?(wait_for_api_projection(id), "journalEvents")

      assert %{
               "data" => %{
                 "journalEvents" => journal_events,
                 "events" => events
               }
             } = wait_for_api_events(id)

      assert journal_events == events
      assert Enum.any?(journal_events, &(&1["type"] == "agent_activity" and &1["address"] == [2]))
      refute Jason.encode!(journal_events) =~ "LIVE-MCP-PROOF-OK"
    end)
  end

  test "GET /api/runs/:id returns a journal-backed run projection" do
    path = demo_workflow()
    id = run_id("scheduler_api_projection")

    conn = post_json(json_conn(), "/api/runs", %{script_path: path, run_id: id, provider: "mock"})

    assert %{"data" => %{"run_id" => ^id}} = json_response(conn, 200)

    assert %{
             "runId" => ^id,
             "state" => "completed",
             "treeName" => "scheduler-api-demo",
             "workflowName" => "scheduler-api-demo",
             "phase" => "draft",
             "logs" => ["ready"],
             "agentCount" => 1,
             "eventCount" => 5,
             "usage" => %{
               "inputTokens" => 0,
               "outputTokens" => 0,
               "totalTokens" => 0
             },
             "result" => "ok",
             "failure" => nil,
             "agents" => [%{"address" => [2], "status" => "completed"}],
             "rejected" => [],
             "verifications" => [],
             "judgments" => [],
             "refines" => [],
             "toolActivity" => [],
             "rawRefs" => %{"journal" => raw_refs},
             "uiPath" => "/runs/" <> ^id,
             "uiUrl" => "/runs/" <> ^id
           } = wait_for_api_projection(id)

    assert Enum.map(raw_refs, & &1["type"]) == [
             "run_started",
             "phase_entered",
             "log_emitted",
             "agent_committed",
             "run_completed"
           ]
  end

  test "GET /api/runs/:id exposes loop_exhausted failures" do
    path =
      write_workflow(~S"""
      workflow "scheduler-api-loop-exhausted" do
        loop max_iterations: 1, on_exhausted: :fail do
          agent "tick"
        end

        return :ok
      end
      """)

    id = run_id("scheduler_api_loop_exhausted")

    conn = post_json(json_conn(), "/api/runs", %{script_path: path, run_id: id, provider: "mock"})

    assert %{"data" => %{"run_id" => ^id, "state" => "accepted"}} = json_response(conn, 200)

    assert %{
             "state" => "failed",
             "failure" => %{
               "address" => [0],
               "attempts" => 0,
               "reason" => reason
             },
             "rawRefs" => %{"journal" => raw_refs}
           } = wait_for_api_state(id, "failed")

    assert reason =~ "loop_exhausted"

    assert Enum.map(raw_refs, & &1["type"]) == [
             "run_started",
             "loop_decision",
             "iteration_started",
             "agent_committed",
             "loop_decision",
             "loop_exhausted"
           ]
  end

  @tag :capture_log
  test "GET /api/runs/:id serializes scheduler-derived lifecycle action semantics" do
    path = demo_workflow()
    completed_id = run_id("scheduler_api_lifecycle_completed")

    conn = post_json(json_conn(), "/api/runs", %{script_path: path, run_id: completed_id, provider: "mock"})

    assert %{"data" => %{"run_id" => ^completed_id}} = json_response(conn, 200)

    assert %{
             "state" => "completed",
             "lifecycleAction" => %{
               "action" => "none",
               "label" => "Finished",
               "enabled" => false,
               "reason" => "Run completed successfully.",
               "method" => nil,
               "href" => nil
             }
           } = wait_for_api_projection(completed_id)

    running_id = run_id("scheduler_api_lifecycle_running")
    {:ok, tree} = Script.load_tree(path)

    assert {:ok, ^running_id, writer} =
             Run.start(tree,
               run_id: running_id,
               provider: {GateProvider, sink: self()},
               script_path: Path.expand(path)
             )

    assert_receive {:agent_called, "ship it"}
    assert_receive {:at_agent, ^writer}

    conn = get(json_conn(), "/api/runs/#{running_id}")

    assert %{
             "data" => %{
               "state" => "running",
               "lifecycleAction" => %{
                 "action" => "pause_unavailable",
                 "label" => "Pause unavailable",
                 "enabled" => false,
                 "method" => nil,
                 "href" => nil
               }
             }
           } = json_response(conn, 200)

    kill_and_await(running_id, writer)

    conn = get(json_conn(), "/api/runs/#{running_id}")

    assert %{
             "data" => %{
               "state" => "running",
               "lifecycleAction" => resume_action
             }
           } = json_response(conn, 200)

    assert resume_action == %{
             "action" => "resume",
             "label" => "Resume",
             "enabled" => true,
             "reason" => "The writer is stopped before a terminal event.",
             "method" => "post",
             "href" => "/api/runs/#{running_id}/resume"
           }
  end

  @tag :capture_log
  test "GET /api/runs/:id serializes resume unavailable for incomplete runs without a script path" do
    path = demo_workflow()
    id = run_id("scheduler_api_lifecycle_missing_script")
    {:ok, tree} = Script.load_tree(path)

    assert {:ok, ^id, writer} =
             Run.start(tree,
               run_id: id,
               provider: {GateProvider, sink: self()}
             )

    assert_receive {:agent_called, "ship it"}
    assert_receive {:at_agent, ^writer}

    kill_and_await(id, writer)

    conn = get(json_conn(), "/api/runs/#{id}")

    assert %{
             "data" => %{
               "state" => "running",
               "lifecycleAction" => %{
                 "action" => "resume_unavailable",
                 "label" => "Resume unavailable",
                 "enabled" => false,
                 "reason" => "No journaled script path is available.",
                 "method" => nil,
                 "href" => nil
               }
             }
           } = json_response(conn, 200)
  end

  test "GET /api/runs/:id/events returns ordered event projections for a known run" do
    path = demo_workflow()
    id = run_id("scheduler_api_events")

    assert {:ok, _start} =
             Workflow.Scheduler.start_run(%{
               "script_path" => path,
               "run_id" => id,
               "provider" => "mock"
             })

    wait_for_api_projection(id)

    assert %{
             "api_version" => "scheduler.v1",
             "data" => %{
               "runId" => ^id,
               "events" => events
             }
           } = wait_for_api_events(id)

    assert Enum.map(events, & &1["seq"]) == [0, 1, 2, 3, 4]

    assert Enum.map(events, & &1["type"]) == [
             "run_started",
             "phase_entered",
             "log_emitted",
             "agent_committed",
             "run_completed"
           ]

    assert [
             %{"seq" => 0, "type" => "run_started"},
             %{"seq" => 1, "type" => "phase_entered", "address" => [0]},
             %{"seq" => 2, "type" => "log_emitted", "address" => [1]},
             %{"seq" => 3, "type" => "agent_committed", "address" => [2]},
             %{"seq" => 4, "type" => "run_completed"}
           ] = events
  end

  test "GET /api/runs/:id/events returns a typed not-found error for unknown runs" do
    id = run_id("scheduler_api_events_missing")

    conn = get(json_conn(), "/api/runs/#{id}/events")

    assert %{
             "api_version" => "scheduler.v1",
             "error" => %{
               "code" => "scheduler.run.not_found",
               "message" => "Workflow run not found.",
               "details" => %{"run_id" => ^id}
             }
           } = json_response(conn, 404)
  end

  test "a run started through POST /api/runs can be inspected through event polling" do
    path = demo_workflow()
    id = run_id("scheduler_api_post_events")

    conn = post_json(json_conn(), "/api/runs", %{script_path: path, run_id: id, provider: "mock"})

    assert %{"data" => %{"run_id" => ^id, "state" => "accepted"}} = json_response(conn, 200)

    assert %{
             "data" => %{
               "runId" => ^id,
               "events" => [
                 %{"type" => "run_started"},
                 %{"type" => "phase_entered"},
                 %{"type" => "log_emitted"},
                 %{"type" => "agent_committed"},
                 %{"type" => "run_completed"}
               ]
             }
           } = wait_for_api_events(id)
  end

  test "POST /api/runs/:id/resume recovers the journaled script and returns an accepted response" do
    path = demo_workflow()
    id = run_id("scheduler_api_resume_completed")

    conn = post_json(json_conn(), "/api/runs", %{script_path: path, run_id: id, provider: "mock"})

    assert %{"data" => %{"run_id" => ^id, "state" => "accepted"}} = json_response(conn, 200)

    before =
      id
      |> wait_for_api_events()
      |> get_in(["data", "events"])

    conn = post_json(json_conn(), "/api/runs/#{id}/resume", %{})

    assert %{
             "api_version" => "scheduler.v1",
             "data" => %{
               "run_id" => ^id,
               "state" => "accepted",
               "ui_path" => "/runs/" <> ^id,
               "ui_url" => "/runs/" <> ^id
             }
           } = json_response(conn, 200)

    await_lease_released(id)

    conn = get(json_conn(), "/api/runs/#{id}/events")
    assert %{"data" => %{"events" => after_events}} = json_response(conn, 200)
    assert Enum.map(after_events, & &1["type"]) == Enum.map(before, & &1["type"])
    assert length(after_events) == length(before)

    projection = json_conn() |> get("/api/runs/#{id}") |> json_response(200) |> Map.fetch!("data")
    assert projection["state"] == "completed"
    assert projection["eventCount"] == length(after_events)
    assert projection["eventCount"] == length(Journal.fold(id))
    assert projection["result"] == "ok"
  end

  test "POST /api/runs/:id/resume returns typed errors for unknown and invalid run ids" do
    unknown = run_id("scheduler_api_resume_unknown")

    conn = post_json(json_conn(), "/api/runs/#{unknown}/resume", %{})

    assert %{
             "api_version" => "scheduler.v1",
             "error" => %{
               "code" => "scheduler.run.not_found",
               "message" => "Workflow run not found.",
               "details" => %{"run_id" => ^unknown}
             }
           } = json_response(conn, 404)

    conn = post_json(json_conn(), "/api/runs/bad$id/resume", %{})

    assert %{
             "api_version" => "scheduler.v1",
             "error" => %{
               "code" => "scheduler.run.invalid_run_id",
               "message" => "Run id must be a non-empty string.",
               "details" => %{
                 "field" => "run_id",
                 "expected" => "route_safe_non_empty_string"
               }
             }
           } = json_response(conn, 400)
  end

  test "POST /api/runs/:id/resume reports missing recovered and missing explicit scripts" do
    path = demo_workflow()
    id = run_id("scheduler_api_resume_missing_recovered")
    {:ok, tree} = Script.load_tree(path)

    assert {:ok, ^id} = Run.run(tree, run_id: id, provider: {Mock, []})

    conn = post_json(json_conn(), "/api/runs/#{id}/resume", %{})

    assert %{
             "api_version" => "scheduler.v1",
             "error" => %{
               "code" => "scheduler.validation.missing_script_path",
               "message" => "Missing workflow script path.",
               "details" => %{"field" => "script_path"}
             }
           } = json_response(conn, 400)

    missing =
      Path.join(
        System.tmp_dir!(),
        "agent_loops_missing_resume_#{System.unique_integer([:positive])}.exs"
      )

    conn = post_json(json_conn(), "/api/runs/#{id}/resume", %{script_path: missing})

    assert %{
             "api_version" => "scheduler.v1",
             "error" => %{
               "code" => "scheduler.validation.script_not_found",
               "message" => "workflow script not found: " <> _,
               "details" => %{
                 "path" => ^missing,
                 "reason" => "workflow script not found: " <> _,
                 "type" => "script_not_found"
               }
             }
           } = json_response(conn, 404)
  end

  test "POST /api/runs/:id/resume validates explicit scripts and provider input" do
    path = demo_workflow()
    id = run_id("scheduler_api_resume_validation")
    {:ok, tree} = Script.load_tree(path)

    assert {:ok, ^id} = Run.run(tree, run_id: id, provider: {Mock, []})

    conn = post_json(json_conn(), "/api/runs/#{id}/resume", %{script_path: bad_workflow(), provider: "mock"})

    assert %{
             "api_version" => "scheduler.v1",
             "error" => %{
               "code" => "scheduler.validation.workflow_dsl",
               "message" => "Workflow script failed validation.",
               "details" => %{
                 "reason" => reason,
                 "type" => "workflow_dsl"
               }
             }
           } = json_response(conn, 422)

    assert reason =~ "unknown combinator `frobnicate`"

    conn = post_json(json_conn(), "/api/runs/#{id}/resume", %{script_path: path, provider: "bogus"})

    assert %{
             "api_version" => "scheduler.v1",
             "error" => %{
               "code" => "scheduler.run.invalid_provider",
               "message" => "Unsupported run provider.",
               "details" => %{"field" => "provider", "supported" => ["mock", "codex"]}
             }
           } = json_response(conn, 400)
  end

  @tag :capture_log
  test "POST /api/runs/:id/resume returns a typed already-running error" do
    path = demo_workflow()
    id = run_id("scheduler_api_resume_running")
    {:ok, tree} = Script.load_tree(path)

    assert {:ok, ^id, writer} =
             Run.start(tree,
               run_id: id,
               provider: {GateProvider, sink: self()},
               script_path: Path.expand(path)
             )

    assert_receive {:agent_called, "ship it"}
    assert_receive {:at_agent, ^writer}

    conn = post_json(json_conn(), "/api/runs/#{id}/resume", %{})

    assert %{
             "api_version" => "scheduler.v1",
             "error" => %{
               "code" => "scheduler.run.already_running",
               "message" => "A workflow run with this id is already running.",
               "details" => %{"run_id" => ^id}
             }
           } = json_response(conn, 409)

    send(writer, :proceed)
    await_lease_released(id)
  end

  @tag :capture_log
  test "POST /api/runs/:id/resume reuses committed effects from the journal" do
    path = two_agent_workflow()
    id = run_id("scheduler_api_resume_once")
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

    conn = post_json(json_conn(), "/api/runs/#{id}/resume", %{})

    assert %{"data" => %{"run_id" => ^id, "state" => "accepted"}} = json_response(conn, 200)

    projection = wait_for_api_projection(id)
    assert projection["eventCount"] == 4

    conn = get(json_conn(), "/api/runs/#{id}/events")
    assert %{"data" => %{"events" => events}} = json_response(conn, 200)

    assert Enum.map(events, & &1["type"]) == [
             "run_started",
             "agent_committed",
             "agent_committed",
             "run_completed"
           ]

    assert events
           |> Enum.filter(&(&1["type"] == "agent_committed"))
           |> Enum.map(& &1["address"]) == [[0], [1]]
  end

  test "POST /api/runs rejects run ids that would break returned UI/API links" do
    path = demo_workflow()

    conn = post_json(json_conn(), "/api/runs", %{script_path: path, run_id: "foo/bar", provider: "mock"})

    assert %{
             "api_version" => "scheduler.v1",
             "error" => %{
               "code" => "scheduler.run.invalid_run_id",
               "message" => "Run id must be a non-empty string.",
               "details" => %{
                 "field" => "run_id",
                 "expected" => "route_safe_non_empty_string"
               }
             }
           } = json_response(conn, 400)

    refute "foo/bar" in Journal.run_ids()
  end

  test "POST /api/workflows/validate validates a workflow script" do
    path = demo_workflow()

    conn = post_json(json_conn(), "/api/workflows/validate", %{script_path: path})

    assert %{
             "api_version" => "scheduler.v1",
             "data" => %{
               "valid" => true,
               "workflow_name" => "scheduler-api-demo",
               "node_count" => 4,
               "script" => %{"path" => ^path}
             }
           } = json_response(conn, 200)
  end

  test "POST /api/workflows/validate validates a same-file schema-backed workflow script" do
    path = schema_backed_workflow()

    conn = post_json(json_conn(), "/api/workflows/validate", %{script_path: path})

    assert %{
             "api_version" => "scheduler.v1",
             "data" => %{
               "valid" => true,
               "workflow_name" => "schema-backed-api",
               "node_count" => 2,
               "script" => %{"path" => ^path}
             }
           } = json_response(conn, 200)
  end

  test "POST /api/workflows/validate returns a typed error for missing scripts" do
    path =
      Path.join(
        System.tmp_dir!(),
        "agent_loops_missing_#{System.unique_integer([:positive])}.exs"
      )

    conn = post_json(json_conn(), "/api/workflows/validate", %{script_path: path})

    assert %{
             "api_version" => "scheduler.v1",
             "error" => %{
               "code" => "scheduler.validation.script_not_found",
               "message" => "workflow script not found: " <> _,
               "details" => %{
                 "path" => ^path,
                 "reason" => "workflow script not found: " <> _,
                 "type" => "script_not_found"
               }
             }
           } = json_response(conn, 404)
  end

  test "POST /api/workflows/validate returns a typed error for malformed workflow DSL" do
    path = bad_workflow()

    conn = post_json(json_conn(), "/api/workflows/validate", %{script_path: path})

    assert %{
             "api_version" => "scheduler.v1",
             "error" => %{
               "code" => "scheduler.validation.workflow_dsl",
               "message" => "Workflow script failed validation.",
               "details" => %{
                 "path" => ^path,
                 "reason" => reason,
                 "type" => "workflow_dsl"
               }
             }
           } = json_response(conn, 422)

    assert reason =~ "unknown combinator `frobnicate`"
  end

  test "POST /api/workflows/validate returns a typed error for syntax errors" do
    path = syntax_error_workflow()

    conn = post_json(json_conn(), "/api/workflows/validate", %{script_path: path})

    assert %{
             "api_version" => "scheduler.v1",
             "error" => %{
               "code" => "scheduler.validation.syntax",
               "message" => "Workflow script failed validation.",
               "details" => %{
                 "path" => ^path,
                 "reason" => reason,
                 "type" => "syntax"
               }
             }
           } = json_response(conn, 422)

    assert reason =~ "missing terminator"
  end

  test "POST /api/workflows/validate returns a typed error for invalid source encoding" do
    path = invalid_encoding_workflow()

    conn = post_json(json_conn(), "/api/workflows/validate", %{script_path: path})

    assert %{
             "api_version" => "scheduler.v1",
             "error" => %{
               "code" => "scheduler.validation.syntax",
               "message" => "Workflow script failed validation.",
               "details" => %{
                 "path" => ^path,
                 "reason" => reason,
                 "type" => "syntax"
               }
             }
           } = json_response(conn, 422)

    assert reason =~ "invalid encoding"
  end

  test "POST /api/workflows/validate returns a typed error for ordinary compile errors" do
    path = compile_error_workflow()
    parent = self()

    capture_io(:stderr, fn ->
      conn = post_json(json_conn(), "/api/workflows/validate", %{script_path: path})

      send(parent, {:conn, conn})
    end)

    assert_received {:conn, conn}

    assert %{
             "api_version" => "scheduler.v1",
             "error" => %{
               "code" => "scheduler.validation.compile",
               "message" => "Workflow script failed validation.",
               "details" => %{
                 "path" => ^path,
                 "reason" => reason,
                 "type" => "compile"
               }
             }
           } = json_response(conn, 422)

    assert reason =~ "cannot compile module"
  end

  test "POST /api/workflows/validate returns a typed error for top-level exceptions" do
    path = top_level_raise_workflow()

    conn = post_json(json_conn(), "/api/workflows/validate", %{script_path: path})

    assert %{
             "api_version" => "scheduler.v1",
             "error" => %{
               "code" => "scheduler.validation.compile",
               "message" => "Workflow script failed validation.",
               "details" => %{
                 "path" => ^path,
                 "reason" => reason,
                 "type" => "compile"
               }
             }
           } = json_response(conn, 422)

    assert reason =~ "boom"
  end

  test "POST /api/workflows/validate returns a typed error for outer top-level script forms" do
    path = outer_top_level_raise_workflow()

    conn = post_json(json_conn(), "/api/workflows/validate", %{script_path: path})

    assert %{
             "api_version" => "scheduler.v1",
             "error" => %{
               "code" => "scheduler.validation.compile",
               "message" => "Workflow script failed validation.",
               "details" => %{
                 "path" => ^path,
                 "reason" => reason,
                 "type" => "compile"
               }
             }
           } = json_response(conn, 422)

    assert reason =~ "outer boom"
  end

  test "POST /api/workflows/validate returns a typed error when use Workflow is missing" do
    path = no_use_workflow()

    conn = post_json(json_conn(), "/api/workflows/validate", %{script_path: path})

    assert %{
             "api_version" => "scheduler.v1",
             "error" => %{
               "code" => "scheduler.validation.compile",
               "message" => "Workflow script failed validation.",
               "details" => %{
                 "path" => ^path,
                 "reason" => reason,
                 "type" => "compile"
               }
             }
           } = json_response(conn, 422)

    assert reason =~ "must `use Workflow`"
  end

  test "POST /api/workflows/validate returns a typed error when workflow appears before use Workflow" do
    path = workflow_before_use_workflow()

    conn = post_json(json_conn(), "/api/workflows/validate", %{script_path: path})

    assert %{
             "api_version" => "scheduler.v1",
             "error" => %{
               "code" => "scheduler.validation.compile",
               "message" => "Workflow script failed validation.",
               "details" => %{
                 "path" => ^path,
                 "reason" => reason,
                 "type" => "compile"
               }
             }
           } = json_response(conn, 422)

    assert reason =~ "must appear after `use Workflow`"
  end

  test "POST /api/workflows/validate returns a typed error for dynamic module headers" do
    path = dynamic_module_header_workflow()

    conn = post_json(json_conn(), "/api/workflows/validate", %{script_path: path})

    assert %{
             "api_version" => "scheduler.v1",
             "error" => %{
               "code" => "scheduler.validation.compile",
               "message" => "Workflow script failed validation.",
               "details" => %{
                 "path" => ^path,
                 "reason" => reason,
                 "type" => "compile"
               }
             }
           } = json_response(conn, 422)

    assert reason =~ "module name must be a literal alias"
  end

  test "POST /api/workflows/validate rejects schema definitions after workflow modules" do
    path = schema_after_workflow()

    conn = post_json(json_conn(), "/api/workflows/validate", %{script_path: path})

    assert %{
             "api_version" => "scheduler.v1",
             "error" => %{
               "code" => "scheduler.validation.compile",
               "message" => "Workflow script failed validation.",
               "details" => %{
                 "path" => ^path,
                 "reason" => reason,
                 "type" => "compile"
               }
             }
           } = json_response(conn, 422)

    assert reason =~ "schema definitions must appear before the workflow module"
  end

  test "POST /api/workflows/validate rejects schemas that redefine scheduler modules" do
    path = schema_redefinition_workflow()
    assert Code.ensure_loaded?(Workflow.Scheduler)
    assert function_exported?(Workflow.Scheduler, :validate_workflow, 1)

    conn = post_json(json_conn(), "/api/workflows/validate", %{script_path: path})

    assert %{
             "api_version" => "scheduler.v1",
             "error" => %{
               "code" => "scheduler.validation.compile",
               "message" => "Workflow script failed validation.",
               "details" => %{
                 "path" => ^path,
                 "reason" => reason,
                 "type" => "compile"
               }
             }
           } = json_response(conn, 422)

    assert reason =~ "would redefine an existing module"
    assert Code.ensure_loaded?(Workflow.Scheduler)
    assert function_exported?(Workflow.Scheduler, :validate_workflow, 1)
    assert {:ok, _health} = Workflow.Scheduler.health()
  end

  test "POST /api/workflows/validate rejects hand-written workflow reflection" do
    path = fake_workflow_reflection()

    conn = post_json(json_conn(), "/api/workflows/validate", %{script_path: path})

    assert %{
             "api_version" => "scheduler.v1",
             "error" => %{
               "code" => "scheduler.validation.compile",
               "message" => "Workflow script failed validation.",
               "details" => %{
                 "path" => ^path,
                 "reason" => reason,
                 "type" => "compile"
               }
             }
           } = json_response(conn, 422)

    assert reason =~ "unsupported top-level workflow script form"
  end

  test "POST /api/workflows/validate rejects forged workflow markers" do
    path = forged_workflow_marker()

    conn = post_json(json_conn(), "/api/workflows/validate", %{script_path: path})

    assert %{
             "api_version" => "scheduler.v1",
             "error" => %{
               "code" => "scheduler.validation.compile",
               "message" => "Workflow script failed validation.",
               "details" => %{
                 "path" => ^path,
                 "reason" => reason,
                 "type" => "compile"
               }
             }
           } = json_response(conn, 422)

    assert reason =~ "unsupported top-level workflow script form"
  end

  test "POST /api/workflows/validate rejects self-registered workflow reflection" do
    path = self_registered_fake_workflow()

    conn = post_json(json_conn(), "/api/workflows/validate", %{script_path: path})

    assert %{
             "api_version" => "scheduler.v1",
             "error" => %{
               "code" => "scheduler.validation.compile",
               "message" => "Workflow script failed validation.",
               "details" => %{
                 "path" => ^path,
                 "reason" => reason,
                 "type" => "compile"
               }
             }
           } = json_response(conn, 422)

    assert reason =~ "unsupported top-level workflow script form"
  end

  test "malformed JSON requests return the scheduler error envelope" do
    conn =
      json_conn()
      |> put_req_header("content-type", "application/json")
      |> post("/api/runs", "{")

    assert %{
             "api_version" => "scheduler.v1",
             "error" => %{
               "code" => "scheduler.malformed_json",
               "message" => "Malformed JSON request body.",
               "details" => %{}
             }
           } = json_response(conn, 400)
  end

  test "unknown API routes return the scheduler error envelope" do
    conn = get(json_conn(), "/api/does-not-exist")

    assert %{
             "api_version" => "scheduler.v1",
             "error" => %{
               "code" => "scheduler.not_found",
               "message" => "Scheduler API route not found.",
               "details" => %{}
             }
           } = json_response(conn, 404)
  end
end
