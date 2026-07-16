defmodule Workflow.WorkflowInputTest do
  use ExUnit.Case, async: true

  alias Workflow.Event
  alias Workflow.Event.Payload
  alias Workflow.Journal
  alias Workflow.PlanIdentity
  alias Workflow.Run
  alias Workflow.Schema
  alias Workflow.Script
  alias Workflow.Test.EchoProvider

  defp run_id, do: "workflow_input_#{System.unique_integer([:positive])}"

  defp write_script(source) do
    path = Path.join(System.tmp_dir!(), "workflow_input_#{System.unique_integer([:positive])}.exs")
    File.write!(path, source)
    path
  end

  defp input_workflow(prompt \\ "Review") do
    write_script("""
    workflow "input-demo",
      inputs: %{
        "type" => "object",
        "properties" => %{
          "topic" => %{"type" => "string"},
          "items" => %{"type" => "array", "items" => %{"type" => "string"}}
        },
        "required" => ["topic", "items"]
      } do
      fanout width: path_count(:args, "/items", max: 4) do
        agent ~P|#{prompt} <%= path(@args, "/topic") %>|
      end

      return :ok
    end
    """)
  end

  test "a workflow declares inert input schema and reserves @args as a run binding" do
    assert {:ok, tree} = Script.load_tree(input_workflow())

    assert Schema.to_map(tree.input_schema) == %{
             "type" => "object",
             "properties" => %{
               "topic" => %{"type" => "string"},
               "items" => %{"type" => "array", "items" => %{"type" => "string"}}
             },
             "required" => ["topic", "items"]
           }

    [fanout, _return] = tree.nodes
    assert fanout.width.ref == :run_input
    assert {:repeat, [%{bindings: %{args: :run_input}}]} = fanout.lanes
  end

  test "args drive nested templates and path-count fanout and are journaled with invocation identity" do
    {:ok, tree} = Script.load_tree(input_workflow())
    id = run_id()
    args = %{"topic" => "payments", "items" => ["one", "two", "three"]}

    assert {:ok, ^id} =
             Run.run(tree,
               run_id: id,
               args: args,
               provider: {EchoProvider, sink: self()}
             )

    for _index <- 1..3, do: assert_received({:agent_called, "Review payments"})
    refute_received {:agent_called, _prompt}

    assert %Event{
             payload: %Payload.RunStarted{
               args: ^args,
               args_digest: args_digest,
               tree_fingerprint: tree_fingerprint
             }
           } = Enum.find(Journal.fold(id), &(&1.type == :run_started))

    assert args_digest == PlanIdentity.input_digest(args)
    assert tree_fingerprint == PlanIdentity.fingerprint(tree)
  end

  test "missing, schema-invalid, and non-JSON args fail before registration or provider work" do
    {:ok, tree} = Script.load_tree(input_workflow())

    missing_id = run_id()

    assert {:error, {:invalid_run_args, {:schema, {:missing_required, "topic"}}}} =
             Run.run(tree, run_id: missing_id, provider: {EchoProvider, sink: self()})

    assert Journal.fold(missing_id) == []

    wrong_type_id = run_id()

    assert {:error, {:invalid_run_args, {:schema, {:property, "topic", {:expected_string, 7}}}}} =
             Run.run(tree,
               run_id: wrong_type_id,
               args: %{"topic" => 7, "items" => []},
               provider: {EchoProvider, sink: self()}
             )

    assert Journal.fold(wrong_type_id) == []

    non_json_id = run_id()

    assert {:error, {:invalid_run_args, :not_json}} =
             Run.run(tree,
               run_id: non_json_id,
               args: %{topic: :payments},
               provider: {EchoProvider, sink: self()}
             )

    assert Journal.fold(non_json_id) == []

    oversized_id = run_id()

    assert {:error, {:invalid_run_args, {:too_large, actual, maximum}}} =
             Run.run(tree,
               run_id: oversized_id,
               args: %{"topic" => String.duplicate("x", 65_536), "items" => []},
               provider: {EchoProvider, sink: self()}
             )

    assert actual > maximum
    assert maximum == 65_536
    assert Journal.fold(oversized_id) == []
    refute_received {:agent_called, _prompt}
  end

  test "workflow options stay literal and :args cannot be shadowed" do
    invalid_schema =
      write_script("""
      workflow "bad-input", inputs: "not a schema" do
        return :ok
      end
      """)

    assert {:error, %Script.Error{kind: :workflow_dsl, message: schema_message}} =
             Script.load_tree(invalid_schema)

    assert schema_message =~ "`inputs:` must be a literal JSON Schema map"

    unknown_option =
      write_script("""
      workflow "bad-option", label: "nope" do
        return :ok
      end
      """)

    assert {:error, %Script.Error{kind: :workflow_dsl, message: option_message}} =
             Script.load_tree(unknown_option)

    assert option_message =~ "unknown workflow option"

    shadowed =
      write_script("""
      workflow "shadowed" do
        let :args = agent("replace input")
        return :ok
      end
      """)

    assert {:error, %Script.Error{kind: :workflow_dsl, message: shadow_message}} =
             Script.load_tree(shadowed)

    assert shadow_message =~ "binding name :args is reserved"
  end

  test "resume reuses journaled args and rejects changed args or a changed plan" do
    {:ok, tree} = Script.load_tree(input_workflow())
    id = run_id()
    args = %{"topic" => "payments", "items" => ["one", "two"]}

    :ok = Journal.register_run(id)
    assert {:ok, %{seq: 0}} = Journal.append_next(id, Event.run_started(tree, nil, nil, nil, args))

    assert {:ok, ^id} = Run.run(tree, run_id: id, provider: {EchoProvider, sink: self()})
    for _index <- 1..2, do: assert_received({:agent_called, "Review payments"})
    refute_received {:agent_called, _prompt}

    event_count = length(Journal.fold(id))

    assert {:error, {:run_args_mismatch, _recorded, _supplied}} =
             Run.run(tree,
               run_id: id,
               args: %{"topic" => "other", "items" => ["one", "two"]},
               provider: {EchoProvider, sink: self()}
             )

    assert length(Journal.fold(id)) == event_count

    {:ok, changed_tree} = "Rewrite" |> input_workflow() |> Script.load_tree()

    assert {:error, {:tree_fingerprint_mismatch, _recorded, _current}} =
             Run.run(changed_tree, run_id: id, provider: {EchoProvider, sink: self()})

    assert length(Journal.fold(id)) == event_count
    refute_received {:agent_called, _prompt}
  end

  test "legacy journals without a plan fingerprint remain resumable" do
    {:ok, tree} =
      Workflow.Compiler.compile(
        "legacy",
        quote do
          agent("continue")
          return(:ok)
        end,
        __ENV__
      )

    id = run_id()
    started = Event.run_started(tree)
    legacy_started = %{started | payload: %{started.payload | tree_fingerprint: nil}}

    :ok = Journal.register_run(id)
    assert {:ok, %{seq: 0}} = Journal.append_next(id, legacy_started)

    assert {:ok, ^id} = Run.run(tree, run_id: id, provider: {EchoProvider, sink: self()})
    assert_received {:agent_called, "continue"}
  end

  test "the plan fingerprint includes the input contract but not invocation values" do
    {:ok, tree} = Script.load_tree(input_workflow())
    {:ok, same_tree} = Script.load_tree(input_workflow())

    assert PlanIdentity.fingerprint(tree) == PlanIdentity.fingerprint(same_tree)
    refute PlanIdentity.input_digest(%{"topic" => "a"}) == PlanIdentity.input_digest(%{"topic" => "b"})

    changed_schema = %{tree | input_schema: Schema.new(%{"type" => "string"})}
    refute PlanIdentity.fingerprint(tree) == PlanIdentity.fingerprint(changed_schema)
  end
end
