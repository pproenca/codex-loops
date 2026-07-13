defmodule Workflow.DataflowCompilerTest do
  @moduledoc """
  Compiler coverage for slice #15's dataflow core: `let`, `~P`, and `emit`.
  Assertions stay at the highest seam — `Workflow.Compiler.compile/3` — so the
  tests pin the inert tree shape and caller-located findings directly.
  """
  use ExUnit.Case, async: true

  alias Workflow.Compiler
  alias Workflow.Compiler.Finding
  alias Workflow.Node.Agent
  alias Workflow.Node.Emit
  alias Workflow.Node.EmitResult
  alias Workflow.Node.Refine
  alias Workflow.Node.Synthesize
  alias Workflow.Template
  alias Workflow.Template.Hole

  defp env, do: %{__ENV__ | file: "workflows/dataflow.ex", line: 1}
  defp parse(source), do: Compiler.compile("test", Code.string_to_quoted!(source), env())

  describe "let bindings and emit terminals" do
    test "binds an agent producer and compiles ~P to an inert template" do
      assert {:ok, tree} =
               parse("""
               let :draft = agent("Write a draft.")
               emit(~P"Final draft: <%= @draft %>")
               """)

      assert [
               %Agent{address: [0], prompt: "Write a draft."},
               %Emit{
                 address: [1],
                 template: %Template{
                   segments: ["Final draft: ", ""],
                   holes: [%Hole{assign: "draft", formatter: :identity}],
                   assigns: ["draft"]
                 },
                 bindings: %{draft: {:node, [0]}}
               }
             ] = tree.nodes

      refute contains_function?(tree)
    end

    test "binds a synthesize producer and resolves it through emit" do
      assert {:ok, tree} =
               parse("""
               let :summary = synthesize(["plan A", "plan B"], "Merge the plans.")
               emit(~P"Summary: <%= @summary %>")
               """)

      assert [
               %Synthesize{
                 address: [0],
                 inputs: ["plan A", "plan B"],
                 prompt: "Merge the plans."
               },
               %Emit{
                 address: [1],
                 template: %Template{
                   segments: ["Summary: ", ""],
                   holes: [%Hole{assign: "summary", formatter: :identity}],
                   assigns: ["summary"]
                 },
                 bindings: %{summary: {:node, [0]}}
               }
             ] = tree.nodes
    end

    test "workflows may terminate with emit" do
      assert {:ok, tree} = parse(~s|emit(~P"done")|)

      assert [
               %Emit{
                 address: [0],
                 template: %Template{segments: ["done"], holes: [], assigns: []}
               }
             ] =
               tree.nodes
    end

    test "emit_result terminates with a result-capable refine binding" do
      assert {:ok, tree} =
               parse("""
               let :final = refine(agent("Draft."),
                 reviewers: [reviewer(:spec, "Review."), reviewer(:runtime, "Runtime.")],
                 revise_with: agent("Fix."),
                 until: :unanimous,
                 max_rounds: 1
               )
               emit_result(:final)
               """)

      assert [
               %Refine{address: [0]},
               %EmitResult{address: [1], binding: :final, ref: {:refine, [0]}}
             ] = tree.nodes
    end

    test "a top-level agent may use a ~P template prompt over an earlier binding" do
      assert {:ok, tree} =
               parse("""
               let :draft = agent("Write a draft.")
               agent(~P"Improve this draft: <%= @draft %>")
               return(:ok)
               """)

      assert [
               %Agent{address: [0], prompt: "Write a draft."},
               %Agent{
                 address: [1],
                 prompt: %Template{
                   segments: ["Improve this draft: ", ""],
                   holes: [%Hole{assign: "draft", formatter: :identity}],
                   assigns: ["draft"]
                 },
                 bindings: %{draft: {:node, [0]}}
               },
               %Workflow.Node.Return{address: [2], value: :ok}
             ] = tree.nodes
    end

    test "a workflow without a terminal return, emit, or emit_result is a located finding" do
      env = %{__ENV__ | file: "workflows/dataflow.ex", line: 7}

      assert {:error, %Finding{line: 7} = f} =
               Compiler.compile("test", Code.string_to_quoted!(~s|phase("p")\nlog("still running")|), env)

      assert f.message =~ "must terminate with `return`, `emit`, or `emit_result`"
      assert Finding.format(f) =~ "workflows/dataflow.ex:7"
    end

    test "a terminal return, emit, or emit_result must be the final top-level node" do
      assert {:error, %Finding{line: 1} = f} = parse(~s|return(:ok)\nlog("after")|)
      assert f.message =~ "must be the final top-level node"

      assert {:error, %Finding{line: 1} = f} =
               parse(~s|emit(~P"done")\nagent("after")|)

      assert f.message =~ "must be the final top-level node"

      assert {:error, %Finding{line: 7} = f} =
               parse("""
               let :final = refine(agent("Draft."),
                 reviewers: [reviewer(:spec, "Review."), reviewer(:runtime, "Runtime.")],
                 revise_with: agent("Fix."),
                 until: :unanimous,
                 max_rounds: 1
               )
               emit_result(:final)
               log("after")
               """)

      assert f.message =~ "must be the final top-level node"
    end

    test "emit_result rejects unknown, non-atom, and non-result bindings" do
      assert {:error, %Finding{} = f} = parse(~s|emit_result(:missing)|)
      assert f.message == "`emit_result` references unknown binding :missing"

      assert {:error, %Finding{} = f} = parse(~s|emit_result(result(:final))|)
      assert f.message == "`emit_result` expects a literal binding atom"

      assert {:error, %Finding{} = f} =
               parse("""
               let :draft = agent("Draft.")
               emit_result(:draft)
               """)

      assert f.message ==
               "`emit_result` requires a result-capable binding; :draft is bound to agent"
    end

    test "emit_result is rejected inside loop bodies" do
      assert {:error, %Finding{} = f} =
               parse("""
               let :final = refine(agent("Draft."),
                 reviewers: [reviewer(:spec, "Review."), reviewer(:runtime, "Runtime.")],
                 revise_with: agent("Fix."),
                 until: :unanimous,
                 max_rounds: 1
               )

               while_budget reserve: 0, max_iterations: 1 do
                 emit_result(:final)
               end

               return(:ok)
               """)

      assert f.message == "`emit_result` is not allowed inside a loop body"
    end

    test "compiles adopted template formatter holes as inert parsed data" do
      assert {:ok, tree} =
               parse("""
               let :review = agent("Review.")
               let :draft = agent("Draft.")
               emit(~P|ID <%= path(@review, "/items/0/id") %> Count <%= count(@review) %> Flat <%= flatten(@review, "/groups") %> Findings <%= numbered_findings(@review, "/items") %> Short <%= truncate(@draft, 5) %>|)
               """)

      assert [
               %Agent{address: [0], prompt: "Review."},
               %Agent{address: [1], prompt: "Draft."},
               %Emit{
                 template: %Template{
                   segments: [
                     "ID ",
                     " Count ",
                     " Flat ",
                     " Findings ",
                     " Short ",
                     ""
                   ],
                   holes: [
                     %Hole{assign: "review", formatter: {:path, "/items/0/id"}},
                     %Hole{assign: "review", formatter: {:count, ""}},
                     %Hole{assign: "review", formatter: {:flatten, "/groups"}},
                     %Hole{assign: "review", formatter: {:numbered_findings, "/items"}},
                     %Hole{assign: "draft", formatter: {:truncate, 5}}
                   ],
                   assigns: ["review", "review", "review", "review", "draft"]
                 },
                 bindings: %{review: {:node, [0]}, draft: {:node, [1]}}
               }
             ] = tree.nodes

      refute contains_function?(tree)
      assert Macro.escape(tree)
    end
  end

  describe "caller-located findings" do
    test "rejects an unbound or forward-referenced assign in emit" do
      assert {:error, %Finding{line: 1} = f} =
               parse(~s|emit(~P"Final draft: <%= @draft %>")|)

      assert f.message =~ "unbound template assign"

      assert {:error, %Finding{line: 1} = f} =
               parse(~s|emit(~P"Final draft: <%= @draft %>")\nlet :draft = agent("Write a draft.")|)

      assert f.message =~ "unbound template assign"
    end

    test "rejects interpolation in prompts" do
      assert {:error, %Finding{line: 1} = f} =
               parse("""
               agent("hi \#{name}")
               return(:ok)
               """)

      assert f.message =~ "interpolation"

      assert {:error, %Finding{line: 1} = f} =
               parse("""
               synthesize(["a"], "merge \#{name}")
               return(:ok)
               """)

      assert f.message =~ "interpolation"
    end

    test "rejects interpolation anywhere in a template" do
      assert {:error, %Finding{line: 2} = f} =
               parse("""
               let :draft = agent("Write a draft.")
               emit(~P"bad \#{name}<%= @draft %>")
               """)

      assert f.message =~ "interpolation"
    end

    test "rejects expression, if, and for holes in templates" do
      assert {:error, %Finding{line: 2} = f} =
               parse("""
               let :draft = agent("Write a draft.")
               emit(~P"Final draft: <%= draft %>")
               """)

      assert f.message =~ "only `<%= @name %>` or closed formatter holes are allowed"

      assert {:error, %Finding{line: 2} = f} =
               parse("""
               let :draft = agent("Write a draft.")
               emit(~P"Final draft: <%= if true do @draft end %>")
               """)

      assert f.message =~ "`if` holes are not allowed"

      assert {:error, %Finding{line: 2} = f} =
               parse("""
               let :draft = agent("Write a draft.")
               emit(~P"Final draft: <%= for item <- [@draft], do: item %>")
               """)

      assert f.message =~ "`for` holes are not allowed"
    end

    test "rejects unsupported template formatter expressions and invalid arguments" do
      assert {:error, %Finding{line: 2} = f} =
               parse("""
               let :review = agent("Review.")
               emit(~P"<%= String.upcase(@review) %>")
               """)

      assert f.message =~ "only `<%= @name %>` or closed formatter holes are allowed"

      assert {:error, %Finding{line: 2} = f} =
               parse("""
               let :review = agent("Review.")
               emit(~P"<%= unknown(@review) %>")
               """)

      assert f.message =~ "only `<%= @name %>` or closed formatter holes are allowed"

      assert {:error, %Finding{line: 2} = f} =
               parse("""
               let :review = agent("Review.")
               emit(~P|<%= path(@review, "open") %>|)
               """)

      assert f.message =~ "invalid JSON pointer"

      assert {:error, %Finding{line: 2} = f} =
               parse("""
               let :review = agent("Review.")
               emit(~P|<%= path(@review, "/a~2b") %>|)
               """)

      assert f.message =~ "invalid JSON pointer"

      assert {:error, %Finding{line: 2} = f} =
               parse("""
               let :draft = agent("Draft.")
               emit(~P"<%= truncate(@draft, -1) %>")
               """)

      assert f.message =~ "truncate formatter expects a non-negative integer"
    end

    test "template holes trim only TemplateWS and truncate accepts only non-negative integer literals" do
      nbsp = <<0xC2, 0xA0>>

      assert {:error, %Finding{line: 2} = f} =
               parse("""
               let :draft = agent("Draft.")
               emit(~P"<%= #{nbsp}@draft#{nbsp} %>")
               """)

      assert f.message =~ "only `<%= @name %>` or closed formatter holes are allowed"

      assert {:error, %Finding{line: 2} = f} =
               parse("""
               let :draft = agent("Draft.")
               emit(~P"<%= truncate(@draft, +1) %>")
               """)

      assert f.message =~ "truncate formatter expects a non-negative integer"

      assert {:error, %Finding{line: 2} = f} =
               parse("""
               let :draft = agent("Draft.")
               emit(~P"<%= truncate(@draft, -0) %>")
               """)

      assert f.message =~ "truncate formatter expects a non-negative integer"

      assert {:ok, tree} =
               parse("""
               let :draft = agent("Draft.")
               emit(~P"<%= truncate(@draft, 1_000) %><%= truncate(@draft, 0x10) %>")
               """)

      assert [
               %Agent{},
               %Emit{
                 template: %Template{
                   holes: [
                     %Hole{formatter: {:truncate, 1000}},
                     %Hole{formatter: {:truncate, 16}}
                   ]
                 }
               }
             ] = tree.nodes
    end

    test "rejects raw statement and comment tags in templates" do
      assert {:error, %Finding{line: 2} = f} =
               parse("""
               let :draft = agent("Write a draft.")
               emit(~P"<% if true do %>x<% end %>")
               """)

      assert f.message =~ "only `<%= @name %>` or closed formatter holes are allowed"

      assert {:error, %Finding{line: 2} = f} =
               parse("""
               let :draft = agent("Write a draft.")
               emit(~P"<%# comment %><%= @draft %>")
               """)

      assert f.message =~ "only `<%= @name %>` or closed formatter holes are allowed"
    end

    test "rejects inadmissible binding names" do
      assert {:error, %Finding{line: 1} = f} = parse(~s|let :ok? = agent("x")\nreturn(:ok)|)
      assert f.message =~ "inadmissible binding name"

      assert {:error, %Finding{line: 1} = f} =
               parse(~s|let :done! = synthesize(["x"], "merge")\nreturn(:ok)|)

      assert f.message =~ "inadmissible binding name"
    end

    test "rejects template prompts in nested agent positions with caller-located findings" do
      assert {:error, %Finding{line: 2} = f} =
               parse("""
               let :draft = agent("Write a draft.")
               parallel([agent(~P"Improve: <%= @draft %>")])
               return(:ok)
               """)

      assert f.message =~ "template prompts are only allowed on top-level agents"
      assert f.message =~ "parallel"

      assert {:error, %Finding{line: 2} = f} =
               parse("""
               let :draft = agent("Write a draft.")
               pipeline(["x"], [agent(~P"Improve: <%= @draft %>")])
               return(:ok)
               """)

      assert f.message =~ "template prompts are only allowed on top-level agents"
      assert f.message =~ "pipeline"

      assert {:error, %Finding{line: 3} = f} =
               parse("""
               let :draft = agent("Write a draft.")
               fan_out width: budget_slices(per: 1) do
                 agent(~P"Improve: <%= @draft %>")
               end
               return(:ok)
               """)

      assert f.message =~ "template prompts are only allowed on top-level agents"
      assert f.message =~ "fanout"

      assert {:error, %Finding{line: 3} = f} =
               parse("""
               let :draft = agent("Write a draft.")
               while_budget reserve: 0 do
                 agent(~P"Improve: <%= @draft %>")
                 collect into: :items
               end
               return(:ok)
               """)

      assert f.message =~ "template prompts are only allowed on top-level agents"
      assert f.message =~ "loop body"
    end
  end

  defp contains_function?(term) when is_function(term), do: true
  defp contains_function?(%_{} = struct), do: struct |> Map.from_struct() |> contains_function?()

  defp contains_function?(map) when is_map(map), do: map |> Map.values() |> Enum.any?(&contains_function?/1)

  defp contains_function?(list) when is_list(list), do: Enum.any?(list, &contains_function?/1)

  defp contains_function?(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> Enum.any?(&contains_function?/1)

  defp contains_function?(_other), do: false
end
