defmodule Workflow.CompilerTest do
  @moduledoc """
  Exercises the DSL at its highest seam — `Workflow.Compiler.compile/3` — directly
  against `quote do ... end` / `Code.string_to_quoted!/1` input, with no macro
  expansion involved. String-sourced bodies give precise, asserted line numbers so
  we can prove diagnostics are caller-located.
  """
  use ExUnit.Case, async: true

  alias Workflow.Compiler
  alias Workflow.Compiler.Finding
  alias Workflow.Node.Agent
  alias Workflow.Node.Log
  alias Workflow.Node.Phase
  alias Workflow.Node.Return

  # An env whose file we control, so located messages are readable and asserted.
  defp env, do: %{__ENV__ | file: "workflows/demo.ex", line: 1}

  # Parse a source string whose line numbers we can assert against directly.
  defp parse(source), do: Compiler.compile("test", Code.string_to_quoted!(source), env())

  describe "accepting the closed vocabulary" do
    test "parses the demo body into an ordered, addressed, inert tree" do
      body =
        quote do
          phase("p")
          log("hi")
          agent("say hello")
          return(:ok)
        end

      assert {:ok, tree} = Compiler.compile("test", body, env())

      assert [
               %Phase{address: [0], name: "p"},
               %Log{address: [1], message: "hi"},
               %Agent{address: [2], prompt: "say hello"},
               %Return{address: [3], value: :ok}
             ] = tree.nodes
    end

    test "parses a single-statement body (not wrapped in a __block__)" do
      assert {:ok, tree} = Compiler.compile("test", quote(do: return(:ok)), env())
      assert [%Return{address: [0], value: :ok}] = tree.nodes
    end

    test "the accepted tree contains no closures anywhere in the term" do
      {:ok, tree} = parse(~s|agent("go")\nreturn(:ok)|)
      refute contains_function?(tree)
    end

    test "a schemaless agent carries a nil schema and the default retry budget" do
      {:ok, tree} = parse(~s|agent("go")\nreturn(:ok)|)
      assert [%Agent{schema: nil, retries: 2, label: nil}, %Return{}] = tree.nodes
    end

    test "an agent label is inert display metadata and does not require a schema" do
      {:ok, tree} = parse(~s|agent("go", label: "read:docs")\nreturn(:ok)|)

      assert [%Agent{prompt: "go", label: "read:docs", schema: nil, retries: 2}, %Return{}] =
               tree.nodes
    end

    test "an agent label composes with schema-backed options" do
      {:ok, tree} =
        parse(~s|agent("go", schema: %{"type" => "object"}, label: "gate:consensus")\nreturn(:ok)|)

      assert [
               %Agent{
                 prompt: "go",
                 label: "gate:consensus",
                 schema: %{"type" => "object"},
                 retries: 2
               },
               %Return{}
             ] = tree.nodes
    end
  end

  describe "schema-backed agent options" do
    test "materializes a nested JSON-schema map literal into inert data" do
      body =
        quote do
          agent("classify",
            schema: %{
              "type" => "object",
              "required" => ["label"],
              "properties" => %{"label" => %{"type" => "string"}}
            }
          )

          return(:ok)
        end

      assert {:ok, tree} = Compiler.compile("test", body, env())

      assert [%Agent{address: [0], prompt: "classify", schema: schema, retries: 2}, %Return{}] =
               tree.nodes

      # The stored schema is a real map, not a fragment of AST, and holds no closures.
      assert schema == %{
               "type" => "object",
               "required" => ["label"],
               "properties" => %{"label" => %{"type" => "string"}}
             }

      refute contains_function?(tree)
    end

    test "an explicit retries budget overrides the default" do
      body =
        quote do
          agent("go", schema: %{"type" => "object"}, retries: 5)
          return(:ok)
        end

      assert {:ok, tree} = Compiler.compile("test", body, env())
      assert [%Agent{retries: 5}, %Return{}] = tree.nodes
    end

    test "agent options with no schema fail closed (located finding)" do
      assert {:error, %Finding{line: 1} = f} = parse("agent(\"go\", retries: 2)\nreturn(:ok)")
      assert f.message =~ "requires a `schema:`"
    end

    test "a non-string label is rejected" do
      assert {:error, %Finding{line: 1} = f} =
               parse(~s|agent("go", schema: %{"type" => "object"}, label: :bad)\nreturn(:ok)|)

      assert f.message =~ "label must be a string literal"
    end

    test "a non-literal / non-map schema is a located finding" do
      assert {:error, %Finding{line: 1} = f} =
               parse("agent(\"go\", schema: build_schema())\nreturn(:ok)")

      assert f.message =~ "schema must be a literal map"

      assert {:error, %Finding{}} = parse(~s|agent("go", schema: "not a map")\nreturn(:ok)|)
    end

    test "an unknown agent option is rejected" do
      assert {:error, %Finding{} = f} =
               parse(~s|agent("go", schema: %{"type" => "object"}, bogus: 1)\nreturn(:ok)|)

      assert f.message =~ "invalid arguments"
    end

    test "a non-integer retries budget is a located finding" do
      assert {:error, %Finding{} = f} =
               parse(~s|agent("go", schema: %{"type" => "object"}, retries: -1)\nreturn(:ok)|)

      assert f.message =~ "non-negative integer"
    end
  end

  describe "forbidden-form catalog (findings, located)" do
    test "rejects a call into an external module — Enum" do
      assert {:error, %Finding{} = finding} = parse("Enum.map([], 1)\nreturn(:ok)")
      assert finding.message =~ "external modules"
      assert Finding.format(finding) =~ "workflows/demo.ex:1"
    end

    test "rejects randomness — :rand — as non-deterministic" do
      assert {:error, %Finding{} = finding} = parse(":rand.uniform()\nreturn(:ok)")
      assert finding.message =~ "external modules"
      assert Finding.format(finding) =~ ":rand.uniform"
    end

    test "rejects wall-clock — System — as non-deterministic" do
      assert {:error, %Finding{} = finding} =
               parse("System.monotonic_time()\nreturn(:ok)")

      assert finding.message =~ "external modules"
      assert Finding.format(finding) =~ "System.monotonic_time"
    end

    test "rejects an anonymous function — the forbidden fn -> ... end form" do
      assert {:error, %Finding{} = finding} = parse("fn -> :nope end\nreturn(:ok)")
      assert finding.message =~ "anonymous functions"
      assert Finding.format(finding) =~ "workflows/demo.ex:1"
    end

    test "rejects a stray literal/variable outside the vocabulary" do
      assert {:error, %Finding{}} = parse("42\nreturn(:ok)")
      assert {:error, %Finding{}} = parse("some_var\nreturn(:ok)")
    end
  end

  describe "unknown combinators carry a closed-vocabulary suggestion" do
    test "a near-miss surfaces a 'did you mean' from the vocabulary, at the user's line" do
      assert {:error, %Finding{} = finding} = parse(~s|phase("p")\nretrun(:ok)|)

      assert finding.message =~ "unknown combinator `retrun`"
      assert finding.hint =~ "did you mean `return`"
      assert Finding.format(finding) =~ "workflows/demo.ex:2"
    end

    test "a far miss still lists the closed vocabulary" do
      assert {:error, %Finding{} = finding} =
               parse(~s|frobnicate("boom")\nreturn(:ok)|)

      assert finding.message =~ "unknown combinator `frobnicate`"
      assert finding.hint =~ "expected one of: agent, log, phase, parallel, pipeline, return"
    end
  end

  describe "per-node option errors (findings, located at the declaration)" do
    test "a known combinator with the wrong argument shape returns a located finding" do
      assert {:error, %Finding{message: msg, line: 1}} =
               parse("agent(:not_a_string)\nreturn(:ok)")

      assert msg =~ "`agent` was called with invalid arguments"

      assert {:error, %Finding{}} = parse(~s|phase("a", "b")\nreturn(:ok)|)
    end

    test "return given a non-literal value is a located finding" do
      assert {:error, %Finding{line: 1} = f} = parse("return(compute())")
      assert f.message =~ "`return` expects a literal value"
    end
  end

  describe "whole-DSL invariants (findings, located at the offending declaration)" do
    test "duplicate phase names fail, citing the second declaration's line" do
      assert {:error, %Finding{line: 2} = f} =
               parse(~s|phase("x")\nphase("x")\nreturn(:ok)|)

      assert f.message =~ ~s|duplicate phase name "x"|
      assert Finding.format(f) =~ "workflows/demo.ex:2"
    end

    test "a workflow with no return fails, located at the workflow declaration" do
      env = %{__ENV__ | file: "workflows/demo.ex", line: 7}

      assert {:error, %Finding{line: 7} = f} =
               Compiler.compile("test", Code.string_to_quoted!(~s|phase("p")\nlog("hi")|), env)

      assert f.message =~ "must terminate with `return`, `emit`, or `emit_result`"
      assert Finding.format(f) =~ "workflows/demo.ex:7"
    end
  end

  # A term with no functions anywhere: proves inertness/serializability.
  defp contains_function?(term) when is_function(term), do: true

  defp contains_function?(%_{} = struct), do: struct |> Map.from_struct() |> contains_function?()

  defp contains_function?(map) when is_map(map), do: map |> Map.values() |> Enum.any?(&contains_function?/1)

  defp contains_function?(list) when is_list(list), do: Enum.any?(list, &contains_function?/1)

  defp contains_function?(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> Enum.any?(&contains_function?/1)

  defp contains_function?(_other), do: false
end
