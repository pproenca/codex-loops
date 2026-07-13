defmodule Workflow.Web.SchedulerAPITest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Plug.Conn, only: [put_req_header: 3]

  alias Workflow.Journal
  alias Workflow.Provider.Codex.AppServer
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
    write_script(block)
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

  defp with_codex_stub(fun) when is_function(fun, 0) do
    python = System.find_executable("python3")
    stub = Path.expand("../../support/codex_app_server_stub.py", __DIR__)

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
      raise "nope"
      return :ok
    end
    """)
  end

  defp syntax_error_workflow do
    dir = Path.join(System.tmp_dir!(), "agent_loops_scheduler_api_test")
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
      workflow "schema-backed-api" do
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
                 "pubsub" => "available"
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

  test "POST /api/runs validates and projects the canonical workspace root" do
    path = demo_workflow()
    workspace_root = Path.dirname(path)
    canonical_root = File.cd!(workspace_root, &File.cwd!/0)
    id = run_id("scheduler_api_workspace")

    conn =
      post_json(json_conn(), "/api/runs", %{
        script_path: path,
        workspace_root: workspace_root,
        run_id: id,
        provider: "mock"
      })

    assert %{"data" => %{"run_id" => ^id}} = json_response(conn, 200)
    assert %{"workspaceRoot" => ^canonical_root} = wait_for_api_projection(id)

    outside_root =
      Path.join(
        System.tmp_dir!(),
        "scheduler_api_outside_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(outside_root)

    try do
      conn =
        post_json(json_conn(), "/api/runs", %{
          script_path: path,
          workspace_root: outside_root,
          run_id: run_id("scheduler_api_workspace_escape"),
          provider: "mock"
        })

      assert %{
               "api_version" => "scheduler.v1",
               "error" => %{
                 "code" => "scheduler.run.script_outside_workspace",
                 "details" => %{
                   "script_path" => canonical_script,
                   "workspace_root" => canonical_outside_root
                 }
               }
             } = json_response(conn, 400)

      assert canonical_script == Path.join(canonical_root, Path.basename(path))
      assert canonical_outside_root == File.cd!(outside_root, &File.cwd!/0)
    after
      File.rm_rf(outside_root)
    end
  end

  test "POST /api/runs can start a codex-provider run with an injected hermetic CLI" do
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
             "eventCount" => 6,
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
             "agent_started",
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
             "agent_started",
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
             "action" => "resume_unavailable",
             "label" => "Resume unavailable",
             "enabled" => false,
             "reason" => "A provider attempt has an unknown outcome; replay could duplicate a paid effect.",
             "method" => nil,
             "href" => nil
           }
  end

  @tag :capture_log
  test "GET /api/runs/:id serializes resume unavailable for incomplete runs without a script path" do
    path = demo_workflow()
    id = run_id("scheduler_api_lifecycle_missing_script")
    {:ok, tree} = Script.load_tree(path)

    assert :ok = Journal.register_run(id)
    assert {:ok, %{seq: 0}} = Journal.append_next(id, Workflow.Event.run_started(tree))

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

    assert Enum.map(events, & &1["seq"]) == [0, 1, 2, 3, 4, 5]

    assert Enum.map(events, & &1["type"]) == [
             "run_started",
             "phase_entered",
             "log_emitted",
             "agent_started",
             "agent_committed",
             "run_completed"
           ]

    assert [
             %{"seq" => 0, "type" => "run_started"},
             %{"seq" => 1, "type" => "phase_entered", "address" => [0]},
             %{"seq" => 2, "type" => "log_emitted", "address" => [1]},
             %{"seq" => 3, "type" => "agent_started", "address" => [2]},
             %{"seq" => 4, "type" => "agent_committed", "address" => [2]},
             %{"seq" => 5, "type" => "run_completed"}
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
                 %{"type" => "agent_started"},
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

    assert reason =~ "unknown combinator `raise`"

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
  test "POST /api/runs/:id/resume fails closed without repeating an unknown effect" do
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

    projection = wait_for_api_state(id, "failed")
    assert projection["eventCount"] == 5
    assert projection["failure"]["reason"] =~ "outcome_unknown"

    conn = get(json_conn(), "/api/runs/#{id}/events")
    assert %{"data" => %{"events" => events}} = json_response(conn, 200)

    assert Enum.map(events, & &1["type"]) == [
             "run_started",
             "agent_started",
             "agent_committed",
             "agent_started",
             "run_failed"
           ]

    assert events
           |> Enum.filter(&(&1["type"] == "agent_committed"))
           |> Enum.map(& &1["address"]) == [[0]]
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

  test "POST /api/workflows/validate validates a literal-schema workflow script" do
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

    assert reason =~ "unknown combinator `raise`"
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

    assert reason =~ "external modules"
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
