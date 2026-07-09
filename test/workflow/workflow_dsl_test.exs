defmodule Workflow.DSLTest do
  @moduledoc "The thin macro produces an inert `__workflow__/1` reflection."
  use ExUnit.Case, async: true

  defmodule DemoWorkflow do
    @moduledoc false
    use Workflow

    workflow "demo" do
      phase("p")
      log("hi")
      agent("say hello")
      return(:ok)
    end
  end

  test "exposes the compiled tree as inert data via __workflow__/1" do
    assert DemoWorkflow.__workflow__(:name) == "demo"

    tree = DemoWorkflow.__workflow__(:tree)
    assert %Workflow.Tree{name: "demo", version: 1} = tree
    assert length(tree.nodes) == 4
    refute contains_function?(tree)
  end

  test "an unknown form in a workflow body fails compilation" do
    source = """
    defmodule Rejected.UnknownForm do
      use Workflow

      workflow "bad" do
        phase "p"
        danger_zone "boom"
      end
    end
    """

    assert_raise Workflow.CompileError, fn -> Code.compile_string(source) end
  end

  # Wrap `body` (indented workflow statements) in a fresh module and compile it as
  # if it were the user's own source file "wf.ex", so failures cite user lines.
  defp reject!(body) do
    source = """
    defmodule Rejected.M#{System.unique_integer([:positive])} do
      use Workflow

      workflow "bad" do
    #{body}
        return :ok
      end
    end
    """

    assert_raise Workflow.CompileError, fn -> Code.compile_string(source, "wf.ex") end
  end

  test "the forbidden-form catalog fails mix compile" do
    assert reject!("    :rand.uniform()").message =~ "external modules"
    assert reject!("    System.monotonic_time()").message =~ "external modules"
    assert reject!("    Enum.map([], fn x -> x end)").message =~ "external modules"
    assert reject!("    fn -> :escape end").message =~ "anonymous functions"
  end

  test "a rejected workflow cites the user's file and line, rustc-style" do
    source = """
    defmodule Rejected.Located do
      use Workflow

      workflow "bad" do
        phase "p"
        frobnicate "boom"
        return :ok
      end
    end
    """

    err = assert_raise Workflow.CompileError, fn -> Code.compile_string(source, "wf.ex") end
    assert err.message =~ "unknown combinator `frobnicate`"
    assert err.message =~ "wf.ex:6"
  end

  test "duplicate phase names fail compile, citing the second declaration" do
    source = """
    defmodule Rejected.Dup do
      use Workflow

      workflow "bad" do
        phase "x"
        phase "x"
        return :ok
      end
    end
    """

    err = assert_raise Workflow.CompileError, fn -> Code.compile_string(source, "wf.ex") end
    assert err.message =~ "duplicate phase name"
    assert err.message =~ "wf.ex:6"
  end

  test "a workflow with no return fails compile" do
    source = """
    defmodule Rejected.NoReturn do
      use Workflow

      workflow "bad" do
        phase "p"
        log "hi"
      end
    end
    """

    err = assert_raise Workflow.CompileError, fn -> Code.compile_string(source, "wf.ex") end
    assert err.message =~ "must terminate with `return`, `emit`, or `emit_result`"
  end

  defp contains_function?(term) when is_function(term), do: true
  defp contains_function?(%_{} = s), do: s |> Map.from_struct() |> contains_function?()

  defp contains_function?(m) when is_map(m), do: m |> Map.values() |> Enum.any?(&contains_function?/1)

  defp contains_function?(l) when is_list(l), do: Enum.any?(l, &contains_function?/1)

  defp contains_function?(t) when is_tuple(t), do: t |> Tuple.to_list() |> Enum.any?(&contains_function?/1)

  defp contains_function?(_), do: false
end
