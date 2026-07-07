defmodule Workflow.SchedulerTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Workflow.Scheduler

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

    assert health.checks == %{
             otp_app: :available,
             journal: :available,
             pubsub: :available,
             endpoint: :available
           }
  end

  test "run start is an expected scheduler API error until lifecycle support ships" do
    assert {:error, %Scheduler.Error{} = error} = Scheduler.start_run(%{})

    assert error.status == 501
    assert error.code == "scheduler.run_start_not_available"
    assert error.message == "Workflow run start is not available in this scheduler API slice."
    assert error.details == %{}
  end

  test "validates an existing workflow script through the scheduler context" do
    path = demo_workflow()
    run_ids = Workflow.Journal.run_ids()

    assert {:ok, validation} = Scheduler.validate_workflow(%{"script_path" => path})

    assert validation.valid == true
    assert validation.workflow_name == "scheduler-demo"
    assert validation.node_count == 4
    assert validation.script == %{path: path}
    assert Workflow.Journal.run_ids() == run_ids
  end

  test "validates a same-file schema-backed workflow script through the scheduler context" do
    path = schema_backed_workflow()
    run_ids = Workflow.Journal.run_ids()

    assert {:ok, validation} = Scheduler.validate_workflow(%{"script_path" => path})

    assert validation.valid == true
    assert validation.workflow_name == "schema-backed"
    assert validation.node_count == 2
    assert validation.script == %{path: path}
    assert Workflow.Journal.run_ids() == run_ids
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
    assert Code.ensure_loaded?(Workflow.Scheduler)
    assert function_exported?(Workflow.Scheduler, :validate_workflow, 1)

    assert {:error, %Scheduler.Error{} = error} =
             Scheduler.validate_workflow(%{"script_path" => path})

    assert error.status == 422
    assert error.code == "scheduler.validation.compile"
    assert error.details.path == path
    assert error.details.type == :compile
    assert error.details.reason =~ "would redefine an existing module"
    assert Code.ensure_loaded?(Workflow.Scheduler)
    assert function_exported?(Workflow.Scheduler, :validate_workflow, 1)
    assert {:ok, _health} = Workflow.Scheduler.health()
  end

  test "same-file schema inlining is scoped to agent options" do
    {path, schema_atom} = return_schema_keyword_workflow()

    assert {:ok, %Workflow.Tree{nodes: [%Workflow.Node.Return{value: value}]}} =
             Workflow.Script.load_tree(path)

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
