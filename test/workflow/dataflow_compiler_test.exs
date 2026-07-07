defmodule Workflow.DataflowCompilerTest do
  @moduledoc """
  Compiler coverage for slice #15's dataflow core: `let`, `~P`, and `emit`.
  Assertions stay at the highest seam — `Workflow.Compiler.parse/2` — so the
  tests pin the inert tree shape and caller-located findings directly.
  """
  use ExUnit.Case, async: true

  alias Workflow.Compiler
  alias Workflow.Compiler.Finding
  alias Workflow.Node.{Agent, Emit, Synthesize}
  alias Workflow.Template

  defp env, do: %{__ENV__ | file: "workflows/dataflow.ex", line: 1}
  defp parse(source), do: Compiler.parse(Code.string_to_quoted!(source), env())

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
                 template: %Template{segments: ["Final draft: ", ""], assigns: ["draft"]},
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
                 template: %Template{segments: ["Summary: ", ""], assigns: ["summary"]},
                 bindings: %{summary: {:node, [0]}}
               }
             ] = tree.nodes
    end

    test "workflows may terminate with emit" do
      assert {:ok, tree} = parse(~s|emit(~P"done")|)

      assert [%Emit{address: [0], template: %Template{segments: ["done"], assigns: []}}] =
               tree.nodes
    end

    test "a workflow without a terminal return or emit is a located finding" do
      env = %{__ENV__ | file: "workflows/dataflow.ex", line: 7}

      assert {:error, %Finding{line: 7} = f} =
               Compiler.parse(Code.string_to_quoted!(~s|phase("p")\nlog("still running")|), env)

      assert f.message =~ "must terminate with `return` or `emit`"
      assert Finding.format(f) =~ "workflows/dataflow.ex:7"
    end

    test "a terminal return or emit must be the final top-level node" do
      assert {:error, %Finding{line: 1} = f} = parse(~s|return(:ok)\nlog("after")|)
      assert f.message =~ "must be the final top-level node"

      assert {:error, %Finding{line: 1} = f} =
               parse(~s|emit(~P"done")\nagent("after")|)

      assert f.message =~ "must be the final top-level node"
    end
  end

  describe "caller-located findings" do
    test "rejects an unbound or forward-referenced assign in emit" do
      assert {:error, %Finding{line: 1} = f} =
               parse(~s|emit(~P"Final draft: <%= @draft %>")|)

      assert f.message =~ "unbound template assign"

      assert {:error, %Finding{line: 1} = f} =
               parse(
                 ~s|emit(~P"Final draft: <%= @draft %>")\nlet :draft = agent("Write a draft.")|
               )

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

      assert f.message =~ "only `<%= @name %>` holes are allowed"

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

    test "rejects raw statement and comment tags in templates" do
      assert {:error, %Finding{line: 2} = f} =
               parse("""
               let :draft = agent("Write a draft.")
               emit(~P"<% if true do %>x<% end %>")
               """)

      assert f.message =~ "only `<%= @name %>` holes are allowed"

      assert {:error, %Finding{line: 2} = f} =
               parse("""
               let :draft = agent("Write a draft.")
               emit(~P"<%# comment %><%= @draft %>")
               """)

      assert f.message =~ "only `<%= @name %>` holes are allowed"
    end

    test "rejects inadmissible binding names" do
      assert {:error, %Finding{line: 1} = f} = parse(~s|let :ok? = agent("x")\nreturn(:ok)|)
      assert f.message =~ "inadmissible binding name"

      assert {:error, %Finding{line: 1} = f} =
               parse(~s|let :done! = synthesize(["x"], "merge")\nreturn(:ok)|)

      assert f.message =~ "inadmissible binding name"
    end
  end

  defp contains_function?(term) when is_function(term), do: true
  defp contains_function?(%_{} = struct), do: struct |> Map.from_struct() |> contains_function?()

  defp contains_function?(map) when is_map(map),
    do: map |> Map.values() |> Enum.any?(&contains_function?/1)

  defp contains_function?(list) when is_list(list), do: Enum.any?(list, &contains_function?/1)

  defp contains_function?(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> Enum.any?(&contains_function?/1)

  defp contains_function?(_other), do: false
end
