defmodule Workflow.Web.SchedulerAPITest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO
  import Phoenix.ConnTest
  import Plug.Conn, only: [put_req_header: 3]

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
    build_conn()
    |> put_req_header("accept", "application/json")
  end

  defp post_json(conn, path, body) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(path, Jason.encode!(body))
  end

  defp run_id(prefix),
    do: "#{prefix}_#{System.unique_integer([:positive])}"

  defp wait_for_api_projection(id, attempts \\ 50)

  defp wait_for_api_projection(id, 0),
    do: flunk("expected GET /api/runs/#{id} to return a completed projection")

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

  test "GET /api/health returns a versioned ready response" do
    conn = get(json_conn(), "/api/health")

    assert %{
             "api_version" => "scheduler.v1",
             "data" => %{
               "status" => "ok",
               "checks" => %{
                 "otp_app" => "available",
                 "journal" => "available",
                 "pubsub" => "available",
                 "endpoint" => "available"
               }
             }
           } = json_response(conn, 200)
  end

  test "POST /api/runs starts a mock-provider run and returns an accepted response" do
    path = demo_workflow()
    id = run_id("scheduler_api_explicit")

    conn =
      json_conn()
      |> post_json("/api/runs", %{
        script_path: path,
        run_id: id,
        provider: "mock",
        budget: 0
      })

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

  test "GET /api/runs/:id returns a journal-backed run projection" do
    path = demo_workflow()
    id = run_id("scheduler_api_projection")

    conn =
      json_conn()
      |> post_json("/api/runs", %{script_path: path, run_id: id, provider: "mock"})

    assert %{"data" => %{"run_id" => ^id}} = json_response(conn, 200)

    assert %{
             "run_id" => ^id,
             "state" => "completed",
             "workflow_name" => "scheduler-api-demo",
             "phase" => "draft",
             "logs" => ["ready"],
             "agent_count" => 1,
             "event_count" => 5,
             "usage" => %{
               "input_tokens" => 0,
               "output_tokens" => 0,
               "total_tokens" => 0
             },
             "result" => "ok",
             "failure" => nil,
             "ui_path" => "/runs/" <> ^id,
             "ui_url" => "/runs/" <> ^id
           } = wait_for_api_projection(id)
  end

  test "POST /api/runs rejects run ids that would break returned UI/API links" do
    path = demo_workflow()

    conn =
      json_conn()
      |> post_json("/api/runs", %{script_path: path, run_id: "foo/bar", provider: "mock"})

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

    refute "foo/bar" in Workflow.Journal.run_ids()
  end

  test "POST /api/workflows/validate validates a workflow script" do
    path = demo_workflow()

    conn =
      json_conn()
      |> post_json("/api/workflows/validate", %{script_path: path})

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

    conn =
      json_conn()
      |> post_json("/api/workflows/validate", %{script_path: path})

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

    conn =
      json_conn()
      |> post_json("/api/workflows/validate", %{script_path: path})

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

    conn =
      json_conn()
      |> post_json("/api/workflows/validate", %{script_path: path})

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

    conn =
      json_conn()
      |> post_json("/api/workflows/validate", %{script_path: path})

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

    conn =
      json_conn()
      |> post_json("/api/workflows/validate", %{script_path: path})

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
      conn =
        json_conn()
        |> post_json("/api/workflows/validate", %{script_path: path})

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

    conn =
      json_conn()
      |> post_json("/api/workflows/validate", %{script_path: path})

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

    conn =
      json_conn()
      |> post_json("/api/workflows/validate", %{script_path: path})

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

    conn =
      json_conn()
      |> post_json("/api/workflows/validate", %{script_path: path})

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

    conn =
      json_conn()
      |> post_json("/api/workflows/validate", %{script_path: path})

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

    conn =
      json_conn()
      |> post_json("/api/workflows/validate", %{script_path: path})

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

    conn =
      json_conn()
      |> post_json("/api/workflows/validate", %{script_path: path})

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

    conn =
      json_conn()
      |> post_json("/api/workflows/validate", %{script_path: path})

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

    conn =
      json_conn()
      |> post_json("/api/workflows/validate", %{script_path: path})

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

    conn =
      json_conn()
      |> post_json("/api/workflows/validate", %{script_path: path})

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

    conn =
      json_conn()
      |> post_json("/api/workflows/validate", %{script_path: path})

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
