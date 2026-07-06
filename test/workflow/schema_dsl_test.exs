defmodule Workflow.SchemaDslTest do
  @moduledoc """
  Exercises the schema sub-DSL at its two seams:

    * `Workflow.Schema.Compiler` — the plain parse/build functions, driven directly
      against `quote do … end` input with no macro expansion, for both the happy
      path and the raise-on-out-of-vocabulary path.
    * the `schema … do … end` macro — compiled real modules, asserting the inert
      JSON-schema map reflected out of `__schema__/1` matches the raw-map shape a
      schema-backed `agent` consumes.
  """
  use ExUnit.Case, async: true

  import Workflow.Schema.DSL

  alias Workflow.Schema.Compiler

  # A module built by the DSL: the RubyLLM-style nested example from the issue.
  schema Bugs do
    array :bugs, of: :object do
      string(:file)
      integer(:line)
      string(:summary)
    end
  end

  # Scalars, an optional field, and an array-of-scalars.
  schema Report do
    string(:title)
    number(:score)
    boolean(:flagged, required: false)
    array(:tags, of: :string)
  end

  defp env, do: %{__ENV__ | file: "schemas/demo.ex", line: 1}

  describe "the schema macro compiles to an inert JSON-schema map" do
    test "nested array of objects matches the raw-map shape #3 consumes" do
      assert Bugs.__schema__(:json) == %{
               "type" => "object",
               "properties" => %{
                 "bugs" => %{
                   "type" => "array",
                   "items" => %{
                     "type" => "object",
                     "properties" => %{
                       "file" => %{"type" => "string"},
                       "line" => %{"type" => "integer"},
                       "summary" => %{"type" => "string"}
                     },
                     "required" => ["file", "line", "summary"]
                   }
                 }
               },
               "required" => ["bugs"]
             }
    end

    test "scalars, an optional field, and an array of scalars" do
      assert Report.__schema__(:json) == %{
               "type" => "object",
               "properties" => %{
                 "title" => %{"type" => "string"},
                 "score" => %{"type" => "number"},
                 "flagged" => %{"type" => "boolean"},
                 "tags" => %{"type" => "array", "items" => %{"type" => "string"}}
               },
               # `flagged` opted out with `required: false`; the rest default required.
               "required" => ["title", "score", "tags"]
             }
    end

    test "the reflected schema is inert data — no closures anywhere in the term" do
      refute contains_function?(Bugs.__schema__(:json))
    end

    test "the zero-arity reflection mirrors the :json reflection" do
      assert Report.__schema__() == Report.__schema__(:json)
    end
  end

  describe "Compiler.parse_object/2 (plain function, no macro expansion)" do
    test "builds an object map from a quoted builder block" do
      block =
        quote do
          string(:a)
          integer(:b)
        end

      assert Compiler.parse_object(block, env()) == %{
               "type" => "object",
               "properties" => %{
                 "a" => %{"type" => "string"},
                 "b" => %{"type" => "integer"}
               },
               "required" => ["a", "b"]
             }
    end

    test "a single-statement block is not wrapped in a __block__" do
      assert Compiler.parse_object(quote(do: string(:only)), env()) == %{
               "type" => "object",
               "properties" => %{"only" => %{"type" => "string"}},
               "required" => ["only"]
             }
    end
  end

  describe "raising on forms outside the closed builder vocabulary" do
    test "an unknown nested builder raises a located CompileError" do
      err =
        assert_raise Workflow.CompileError, fn ->
          Compiler.parse_object(quote(do: mystery(:x)), env())
        end

      assert err.message =~ "unknown schema builder"
      assert err.message =~ "schemas/demo.ex:1"
    end

    test "a non-literal field name raises" do
      err =
        assert_raise Workflow.CompileError, fn ->
          Compiler.parse_object(quote(do: string(some_var)), env())
        end

      assert err.message =~ "must be a literal atom"
    end

    test "an array with no item type raises" do
      err =
        assert_raise Workflow.CompileError, fn ->
          Compiler.array_field(:xs, [], nil, env())
        end

      assert err.message =~ "requires an `of:`"
    end

    test "`of: :object` without a body raises" do
      err =
        assert_raise Workflow.CompileError, fn ->
          Compiler.array_field(:xs, [of: :object], nil, env())
        end

      assert err.message =~ "requires a `do` block"
    end

    test "an unknown item type raises" do
      err =
        assert_raise Workflow.CompileError, fn ->
          Compiler.array_field(:xs, [of: :widget], nil, env())
        end

      assert err.message =~ "unknown item type"
    end

    test "an unknown scalar option raises" do
      err =
        assert_raise Workflow.CompileError, fn ->
          Compiler.scalar_field(:string, :a, [bogus: true], env())
        end

      assert err.message =~ "invalid schema field options"
    end

    test "an out-of-vocabulary builder inside a compiled schema fails compilation" do
      assert_raise Workflow.CompileError, fn ->
        Code.compile_string("""
        import Workflow.Schema.DSL

        schema Workflow.SchemaDslTest.BadNested do
          array :xs, of: :object do
            mystery :x
          end
        end
        """)
      end
    end

    test "a stray top-level expression raises rather than executing at compile time" do
      # The top-level body is parsed as inert data through the same vocabulary gate
      # as nested bodies: a bare expression is never spliced into module-body
      # position, so it cannot run a compile-time side effect — it raises.
      err =
        assert_raise Workflow.CompileError, fn ->
          Code.compile_string("""
          import Workflow.Schema.DSL

          schema Workflow.SchemaDslTest.BadTopLevel do
            send(self(), :SIDE_EFFECT_RAN)
            string :a
          end
          """)
        end

      assert err.message =~ "unknown schema builder"
      refute_received :SIDE_EFFECT_RAN
    end
  end

  # A structural closure probe over the reflected term.
  defp contains_function?(fun) when is_function(fun), do: true
  defp contains_function?(%{} = map), do: Enum.any?(map, &contains_function?/1)
  defp contains_function?(list) when is_list(list), do: Enum.any?(list, &contains_function?/1)
  defp contains_function?({k, v}), do: contains_function?(k) or contains_function?(v)

  defp contains_function?(tuple) when is_tuple(tuple),
    do: contains_function?(Tuple.to_list(tuple))

  defp contains_function?(_), do: false
end
