import Workflow.Schema.DSL

# A schema module built by the sub-DSL, defined before the workflows that reference
# it so the compile-time reflection resolves.
schema SchemaAgentFixtures.BugReport do
  array :bugs, of: :object do
    string(:file)
    integer(:line)
  end
end

defmodule SchemaAgentFixtures.ViaModule do
  use Workflow

  workflow "via_module" do
    agent("find bugs", schema: SchemaAgentFixtures.BugReport)
    return(:ok)
  end
end

defmodule SchemaAgentFixtures.ViaRawMap do
  use Workflow

  workflow "via_raw_map" do
    agent("find bugs",
      schema: %{
        "type" => "object",
        "properties" => %{
          "bugs" => %{
            "type" => "array",
            "items" => %{
              "type" => "object",
              "properties" => %{
                "file" => %{"type" => "string"},
                "line" => %{"type" => "integer"}
              },
              "required" => ["file", "line"]
            }
          }
        },
        "required" => ["bugs"]
      }
    )

    return(:ok)
  end
end

defmodule Workflow.SchemaAgentTest do
  @moduledoc """
  Proves the acceptance criterion that `agent "…", schema: Bugs` behaves
  identically to the raw-map form from #3 — first by structural equality of the
  compiled inert tree, then by driving both through the interpreter over a
  call-counting mock provider and asserting identical fail-closed behaviour.
  """
  use ExUnit.Case, async: true

  alias Workflow.{Run, Journal, Status}
  alias Workflow.Test.ScriptedProvider

  @via_module SchemaAgentFixtures.ViaModule
  @via_raw SchemaAgentFixtures.ViaRawMap

  @valid %{"bugs" => [%{"file" => "lib/a.ex", "line" => 3}]}

  defp run_id, do: "run_#{System.unique_integer([:positive])}"

  defp provider(outputs) do
    {:ok, script} = ScriptedProvider.start(outputs)
    {ScriptedProvider, sink: self(), script: script}
  end

  defp agent_schema(module) do
    [%Workflow.Node.Agent{schema: schema} | _] = module.__workflow__(:tree).nodes
    schema
  end

  defp types(id), do: Journal.fold(id) |> Enum.map(& &1.type)

  test "the module-backed agent compiles to exactly the raw map from #3" do
    assert agent_schema(@via_module) == SchemaAgentFixtures.BugReport.__schema__(:json)
    assert agent_schema(@via_module) == agent_schema(@via_raw)
  end

  test "a conforming output is validated and committed, identically for both forms" do
    for module <- [@via_module, @via_raw] do
      id = run_id()
      assert {:ok, ^id} = Run.run(module, run_id: id, provider: provider([@valid]))

      assert_received {:agent_called, "find bugs"}
      refute_received {:agent_called, _}

      committed = Enum.find(Journal.fold(id), &(&1.type == :agent_committed))
      assert committed.payload.result == @valid
      assert types(id) == [:run_started, :agent_committed, :run_completed]
      assert Status.of(id).state == :completed
    end
  end

  test "a schema-violating output fails closed after exhausting retries, for both forms" do
    # `bugs` present but not a list -> the array check rejects every attempt.
    outputs = [%{"bugs" => "nope"}, %{"bugs" => "still"}, %{"bugs" => "no"}]

    for module <- [@via_module, @via_raw] do
      id = run_id()

      assert {:error, {:malformed_output, [0], _reason}} =
               Run.run(module, run_id: id, provider: provider(outputs))

      # Default budget: three attempts, all on-thread, then a terminal failure.
      for _ <- 1..3, do: assert_received({:agent_called, "find bugs"})
      refute_received {:agent_called, _}

      assert types(id) ==
               [
                 :run_started,
                 :agent_attempt_rejected,
                 :agent_attempt_rejected,
                 :agent_attempt_rejected,
                 :agent_failed
               ]

      status = Status.of(id)
      assert status.state == :failed
      assert status.failure.attempts == 3
    end
  end

  test "a non-schema module reference is a located compile finding, not a raise-through" do
    # `Enum` is a real module with no `__schema__/1`.
    body = quote(do: agent("x", schema: Enum))

    assert {:error, %Workflow.Compiler.Finding{} = finding} =
             Workflow.Compiler.parse(
               quote do
                 unquote(body)
                 return(:ok)
               end,
               __ENV__
             )

    assert finding.message =~ "is not a schema"
  end
end
