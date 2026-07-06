defmodule Workflow.Schema.DSL do
  @moduledoc """
  A declarative, compile-time schema builder in the shape of RubyLLM::Schema:

      import Workflow.Schema.DSL

      schema Bugs do
        array :bugs, of: :object do
          string :file
          integer :line
          string :summary
        end
      end

  `schema Name do … end` defines a module `Name` whose only job is to expose an
  **inert JSON-schema map** through `Name.__schema__(:json)` — the exact raw-map
  shape a schema-backed `agent` consumes (slice #3), so `agent "…", schema: Name`
  behaves identically to passing that map literally.

  ## Why a thin shell over `Workflow.Schema.Compiler`

  This macro is a **thin shell**: it does no parsing of its own. It hands the raw
  do-block AST to the plain function `Workflow.Schema.Compiler.parse_object/2`,
  which walks the body **as data** and folds it into a finished JSON-schema map at
  expansion time. The block is never spliced into executable position, so nothing
  in it is ever evaluated as compile-time module-body code — the same total,
  fail-closed vocabulary gate the nested `array … of: :object do … end` body goes
  through also guards the top level. Any form outside the closed builder
  vocabulary (`string`, `integer`, `number`, `boolean`, `array`) — an unknown
  builder, a non-literal field name, a stray expression — **raises** a
  caller-located `Workflow.CompileError`, so a malformed schema fails `mix
  compile`, never at runtime.

  The finished map is `Macro.escape/1`d and spliced into the reflection function as
  a compile-time constant. The tree stays pure data — no closure is ever captured —
  so it can be journaled, folded, and resumed like any other inert node.
  """

  alias Workflow.Schema.Compiler

  defmacro __using__(_opts) do
    quote do
      import Workflow.Schema.DSL, only: [schema: 2]
    end
  end

  @doc """
  Define an inert JSON-schema module from a builder block.

  Parses the raw do-block AST through `Compiler.parse_object/2` at expansion time —
  the body is walked as data, never expanded or executed — and splices the finished
  JSON-schema map into `__schema__/1` as a compile-time constant. Any form outside
  the closed builder vocabulary raises, so a malformed schema fails `mix compile`.
  """
  defmacro schema(name, do: block) do
    json = block |> Compiler.parse_object(__CALLER__) |> Macro.escape()

    quote do
      defmodule unquote(name) do
        def __schema__(:json), do: unquote(json)
        def __schema__, do: unquote(json)
      end
    end
  end
end
