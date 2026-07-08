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
