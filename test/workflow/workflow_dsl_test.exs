defmodule Workflow.PathFirstCompilerTest do
  use ExUnit.Case, async: false

  alias Workflow.Compiler
  alias Workflow.Compiler.Finding
  alias Workflow.Script
  alias Workflow.Tree

  defp compile(body), do: Compiler.compile("demo", body, %{__ENV__ | file: "wf.ex"})

  defp write_script(source) do
    path =
      Path.join(
        System.tmp_dir!(),
        "workflow_compiler_#{System.unique_integer([:positive])}.exs"
      )

    File.write!(path, source)
    path
  end

  test "compiles quoted vocabulary into inert tree data" do
    assert {:ok, %Tree{name: "demo", version: 1, nodes: nodes} = tree} =
             compile(
               quote do
                 phase("p")
                 log("hi")
                 agent("say hello")
                 return(:ok)
               end
             )

    assert length(nodes) == 4
    refute contains_function?(tree)
  end

  test "returns located findings for forms outside the vocabulary" do
    for {body, message} <- [
          {quote(do: :rand.uniform()), "external modules"},
          {quote(do: System.monotonic_time()), "external modules"},
          {quote(do: Enum.map([], fn x -> x end)), "external modules"},
          {quote(do: fn -> :escape end), "anonymous functions"},
          {quote(do: danger_zone("boom")), "unknown combinator `danger_zone`"}
        ] do
      assert {:error, %Finding{file: "wf.ex", message: actual}} = compile(body)
      assert actual =~ message
    end
  end

  test "returns findings for whole-tree invariants" do
    assert {:error, %Finding{message: duplicate}} =
             compile(
               quote do
                 phase("x")
                 phase("x")
                 return(:ok)
               end
             )

    assert duplicate =~ "duplicate phase name"

    assert {:error, %Finding{message: missing_terminal}} =
             compile(
               quote do
                 phase("p")
                 log("hi")
               end
             )

    assert missing_terminal =~ "must terminate with `return`, `emit`, or `emit_result`"
  end

  test "Script accepts one bare top-level workflow form" do
    path =
      write_script(~S"""
      workflow "path-first" do
        agent "do it"
        return :ok
      end
      """)

    assert {:ok, %Tree{name: "path-first", nodes: [_, _]}} = Script.load_tree(path)
  end

  test "Script rejects wrappers and additional top-level forms without evaluating them" do
    wrapped =
      write_script(~S"""
      defmodule Workflow do
        workflow "wrapped" do
          return :ok
        end
      end
      """)

    assert {:error, %Script.Error{kind: :compile, message: wrapped_message}} =
             Script.load_tree(wrapped)

    assert wrapped_message =~ "unsupported top-level workflow script form"

    multiple =
      write_script(~S"""
      workflow "one" do
        return :ok
      end

      workflow "two" do
        return :ok
      end
      """)

    assert {:error, %Script.Error{kind: :workflow_dsl, message: multiple_message}} =
             Script.load_tree(multiple)

    assert multiple_message =~ "exactly one top-level form"
  end

  test "Script rejects source larger than its fixed input bound before parsing" do
    path = write_script(String.duplicate(" ", 1024 * 1024 + 1))

    assert {:error, %Script.Error{kind: :compile, message: message}} = Script.load_tree(path)
    assert message =~ "maximum is 1048576 bytes"
  end

  test "Script rejects unknown source atoms without growing the VM atom table" do
    unknown = "workflow_never_loaded_#{System.unique_integer([:positive])}"

    path =
      write_script("""
      workflow "unknown-atom" do
        #{unknown}()
        return :ok
      end
      """)

    before = :erlang.system_info(:atom_count)
    assert {:error, %Script.Error{kind: :syntax, message: message}} = Script.load_tree(path)
    after_load = :erlang.system_info(:atom_count)

    assert message =~ "unsafe atom does not exist"
    assert after_load == before
  end

  test "Script reports invalid UTF-8 as a typed syntax error" do
    path = write_script(<<255, 254, 253>>)

    assert {:error, %Script.Error{kind: :syntax, message: message}} = Script.load_tree(path)
    assert message =~ "invalid encoding"
  end

  defp contains_function?(term) when is_function(term), do: true
  defp contains_function?(%_{} = struct), do: struct |> Map.from_struct() |> contains_function?()

  defp contains_function?(map) when is_map(map), do: map |> Map.values() |> Enum.any?(&contains_function?/1)

  defp contains_function?(list) when is_list(list), do: Enum.any?(list, &contains_function?/1)

  defp contains_function?(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> Enum.any?(&contains_function?/1)

  defp contains_function?(_term), do: false
end
