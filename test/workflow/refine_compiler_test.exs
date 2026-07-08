defmodule Workflow.RefineCompilerTest do
  use ExUnit.Case, async: true

  alias Workflow.Compiler
  alias Workflow.Node.{Agent, Refine, Return}

  defp env, do: %{__ENV__ | file: "workflows/refine.ex", line: 1}
  defp parse(source), do: Compiler.parse(Code.string_to_quoted!(source), env())

  test "compiles a top-level inline producer refine into pre-addressed role agents" do
    {:ok, tree} =
      parse("""
      refine agent("Draft."),
        reviewers: [
          reviewer(:spec, "Find spec gaps."),
          reviewer(:runtime, "Find runtime bugs.")
        ],
        revise_with: agent("Fix."),
        until: :unanimous,
        max_rounds: 3

      return(:ok)
      """)

    assert [
             %Refine{
               address: [0],
               input:
                 {:producer,
                  %Agent{
                    address: [0, 0],
                    prompt: "Draft.",
                    schema: %{"required" => ["artifact"]}
                  }},
               reviewers: [
                 %{index: 0, name: :spec, prompt: "Find spec gaps.", agent: %Agent{} = spec},
                 %{
                   index: 1,
                   name: :runtime,
                   prompt: "Find runtime bugs.",
                   agent: %Agent{} = runtime
                 }
               ],
               reviser: %Agent{
                 address: [0, 2],
                 prompt: "Fix.",
                 schema: %{"required" => ["artifact"]}
               },
               until: :unanimous,
               max_rounds: 3,
               max_concurrency: 2
             },
             %Return{value: :ok}
           ] = tree.nodes

    assert spec.address == [0, 1, 0]
    assert runtime.address == [0, 1, 1]
    assert spec.retries == 0
    assert runtime.retries == 0
    assert spec.schema["additionalProperties"] == false
    assert spec.schema["required"] == ["approved", "findings"]
    assert spec.schema["properties"]["findings"]["items"]["additionalProperties"] == false
    assert runtime.schema["properties"]["findings"]["type"] == "array"
  end

  test "compiles reviewer adapters into metadata and adapter-owned schemas" do
    {:ok, tree} =
      parse("""
      refine agent("Draft."),
        reviewers: [
          reviewer(:findings, "Find findings."),
          reviewer(:defects, "Find defects.", adapter: :defects_v1),
          reviewer(:violations, "Find violations.", adapter: :violations_v1),
          reviewer(:concerns, "Find concerns.", adapter: :concerns_v1)
        ],
        revise_with: agent("Fix."),
        until: :unanimous,
        max_rounds: 1

      return(:ok)
      """)

    assert [%Refine{reviewers: reviewers}] = Enum.take(tree.nodes, 1)

    assert Enum.map(reviewers, &{&1.name, &1.adapter}) == [
             {:findings, :findings_v1},
             {:defects, :defects_v1},
             {:violations, :violations_v1},
             {:concerns, :concerns_v1}
           ]

    [findings, defects, violations, concerns] = Enum.map(reviewers, & &1.agent.schema)

    assert findings["required"] == ["approved", "findings"]

    assert findings["properties"]["findings"]["items"]["required"] == [
             "id",
             "blocking",
             "issue",
             "fix"
           ]

    assert defects["required"] == ["pass", "defects"]

    assert defects["properties"]["defects"]["items"]["required"] == [
             "id",
             "blocking",
             "issue",
             "fix"
           ]

    assert violations["required"] == ["pass", "violations"]
    assert violations["properties"]["violations"]["items"]["required"] == ["id", "issue", "fix"]

    assert violations["properties"]["violations"]["items"]["properties"]["severity"] == %{
             "type" => "string"
           }

    assert concerns["required"] == ["verdict", "concerns"]
    assert concerns["properties"]["verdict"]["enum"] == ["approve", "changes"]

    assert concerns["properties"]["concerns"]["items"]["required"] == [
             "id",
             "blocking",
             "concern",
             "recommendation"
           ]
  end

  test "compiles closed refine gates into cold-read and repair role descriptors" do
    {:ok, tree} =
      parse("""
      refine agent("Draft."),
        reviewers: [
          reviewer(:spec, "Find spec gaps."),
          reviewer(:runtime, "Find runtime bugs.")
        ],
        revise_with: agent("Fix."),
        until: :unanimous,
        max_rounds: 1,
        gates: [
          cold_read: [
            reviewer: reviewer(:cold, "Cold read.", adapter: :concerns_v1),
            when: path_non_empty("/openFindings")
          ],
          repair_when: path_non_empty("/coldRead/openFindings"),
          halt_when: path_count("/finalOpenDefects") > 0
        ]

      return(:ok)
      """)

    assert [
             %Refine{
               gates: %{
                 cold_read: %{
                   predicate: {:path_non_empty, "/openFindings"},
                   reviewer: %{
                     name: :cold,
                     adapter: :concerns_v1,
                     agent: %Agent{address: [0, 3], prompt: "Cold read."}
                   }
                 },
                 repair: %{
                   predicate: {:path_non_empty, "/coldRead/openFindings"},
                   agent: %Agent{address: [0, 4], prompt: "Fix."}
                 },
                 halt: %{predicate: {:path_count, "/finalOpenDefects", :>, 0}}
               }
             },
             %Return{}
           ] = tree.nodes
  end

  test "rejects invalid refine gate option shapes" do
    assert {:error, %Workflow.Compiler.Finding{} = finding} =
             parse("""
             refine agent("Draft."),
               reviewers: [reviewer(:spec, "Find spec gaps."), reviewer(:runtime, "Find runtime bugs.")],
               revise_with: agent("Fix."),
               until: :unanimous,
               max_rounds: 1,
               gates: path_non_empty("/openFindings")

             return(:ok)
             """)

    assert finding.message =~ "`refine` `gates:` must be a literal keyword list"

    assert {:error, %Workflow.Compiler.Finding{} = finding} =
             parse("""
             refine agent("Draft."),
               reviewers: [reviewer(:spec, "Find spec gaps."), reviewer(:runtime, "Find runtime bugs.")],
               revise_with: agent("Fix."),
               until: :unanimous,
               max_rounds: 1,
               gates: [
                 repair_when: path_non_empty("/openFindings"),
                 repair_when: path_exists("/coldRead")
               ]

             return(:ok)
             """)

    assert finding.message =~ "`refine` gate `repair_when:` must appear at most once"
  end

  test "rejects invalid refine gate predicates and literals" do
    assert {:error, %Workflow.Compiler.Finding{} = finding} =
             parse("""
             refine agent("Draft."),
               reviewers: [reviewer(:spec, "Find spec gaps."), reviewer(:runtime, "Find runtime bugs.")],
               revise_with: agent("Fix."),
               until: :unanimous,
               max_rounds: 1,
               gates: [repair_when: path_non_empty("openFindings")]

             return(:ok)
             """)

    assert finding.message =~ "gate JSON pointer"

    assert {:error, %Workflow.Compiler.Finding{} = finding} =
             parse("""
             refine agent("Draft."),
               reviewers: [reviewer(:spec, "Find spec gaps."), reviewer(:runtime, "Find runtime bugs.")],
               revise_with: agent("Fix."),
               until: :unanimous,
               max_rounds: 1,
               gates: [halt_when: path_count("/finalOpenDefects") != 0]

             return(:ok)
             """)

    assert finding.message =~ "`path_count` gate must compare with one of"

    assert {:error, %Workflow.Compiler.Finding{} = finding} =
             parse("""
             refine agent("Draft."),
               reviewers: [reviewer(:spec, "Find spec gaps."), reviewer(:runtime, "Find runtime bugs.")],
               revise_with: agent("Fix."),
               until: :unanimous,
               max_rounds: 1,
               gates: [halt_when: path_equals("/x", %{"a" => 1, a: 2})]

             return(:ok)
             """)

    assert finding.message =~ "duplicate object key"
  end

  test "rejects invalid cold-read gate descriptors" do
    assert {:error, %Workflow.Compiler.Finding{} = finding} =
             parse("""
             refine agent("Draft."),
               reviewers: [reviewer(:spec, "Find spec gaps."), reviewer(:runtime, "Find runtime bugs.")],
               revise_with: agent("Fix."),
               until: :unanimous,
               max_rounds: 1,
               gates: [cold_read: [when: path_non_empty("/openFindings")]]

             return(:ok)
             """)

    assert finding.message =~ "`cold_read:` requires `reviewer:`"

    assert {:error, %Workflow.Compiler.Finding{} = finding} =
             parse("""
             refine agent("Draft."),
               reviewers: [reviewer(:spec, "Find spec gaps."), reviewer(:runtime, "Find runtime bugs.")],
               revise_with: agent("Fix."),
               until: :unanimous,
               max_rounds: 1,
               gates: [
                 cold_read: [
                   reviewer: reviewer(:cold, "Cold read."),
                   when: unknown_gate("/openFindings")
                 ]
               ]

             return(:ok)
             """)

    assert finding.message =~ "unknown refine gate predicate"
  end

  test "rejects unsupported reviewer adapter options" do
    assert {:error, %Workflow.Compiler.Finding{} = finding} =
             parse("""
             refine agent("Draft."),
               reviewers: [
                 reviewer(:spec, "Find spec gaps.", adapter: :unknown_v1),
                 reviewer(:runtime, "Find runtime bugs.")
               ],
               revise_with: agent("Fix."),
               until: :unanimous,
               max_rounds: 3

             return(:ok)
             """)

    assert finding.message =~ "unsupported reviewer adapter"

    assert {:error, %Workflow.Compiler.Finding{} = finding} =
             parse("""
             refine agent("Draft."),
               reviewers: [
                 reviewer(:spec, "Find spec gaps.", schema: %{}),
                 reviewer(:runtime, "Find runtime bugs.")
               ],
               revise_with: agent("Fix."),
               until: :unanimous,
               max_rounds: 3

             return(:ok)
             """)

    assert finding.message =~ "`reviewer` options may only include `adapter:`"
  end

  test "compiles bound artifact input by capturing the prior let binding ref" do
    {:ok, tree} =
      parse("""
      let :draft = agent("Draft.")

      refine :draft,
        reviewers: [
          reviewer(:spec, "Find spec gaps."),
          reviewer(:runtime, "Find runtime bugs.")
        ],
        revise_with: agent("Fix."),
        until: :unanimous,
        max_rounds: 3

      return(:ok)
      """)

    assert [
             %Agent{address: [0]},
             %Refine{address: [1], input: {:binding, :draft, {:node, [0]}}},
             %Return{value: :ok}
           ] = tree.nodes
  end

  test "binds refine producers through a refine binding ref" do
    {:ok, tree} =
      parse("""
      let :final = refine agent("Draft."),
        reviewers: [
          reviewer(:spec, "Find spec gaps."),
          reviewer(:runtime, "Find runtime bugs.")
        ],
        revise_with: agent("Fix."),
        until: :unanimous,
        max_rounds: 1,
        on_non_convergence: :accept_current

      emit(~P"Final: <%= @final %>")
      """)

    assert [
             %Refine{address: [0]},
             %Workflow.Node.Emit{bindings: %{final: {:refine, [0]}}}
           ] = tree.nodes
  end

  test "rejects duplicate required refine options" do
    assert {:error, %Workflow.Compiler.Finding{} = finding} =
             parse("""
             refine agent("Draft."),
               reviewers: [reviewer(:spec, "Find spec gaps."), reviewer(:runtime, "Find runtime bugs.")],
               reviewers: [reviewer(:other, "Find other gaps."), reviewer(:extra, "Find extra bugs.")],
               revise_with: agent("Fix."),
               until: :unanimous,
               max_rounds: 3

             return(:ok)
             """)

    assert finding.message =~ "`refine` option `reviewers:` must appear exactly once"
  end

  test "rejects duplicate optional refine options" do
    assert {:error, %Workflow.Compiler.Finding{} = finding} =
             parse("""
             refine agent("Draft."),
               reviewers: [reviewer(:spec, "Find spec gaps."), reviewer(:runtime, "Find runtime bugs.")],
               revise_with: agent("Fix."),
               until: :unanimous,
               max_rounds: 3,
               max_concurrency: 1,
               max_concurrency: 2

             return(:ok)
             """)

    assert finding.message =~ "`refine` option `max_concurrency:` must appear at most once"
  end
end
