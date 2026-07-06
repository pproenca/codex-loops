defmodule Workflow.Schema.Compiler do
  @moduledoc """
  Turns the declarative schema builder vocabulary into an **inert JSON-schema map**
  at compile time — the same raw-map shape a schema-backed `agent` consumes in
  slice #3, so a `schema` module is a drop-in replacement for a hand-written map.

  This is a plain function module, deliberately *not* a macro: all parsing and
  validation live here so they can be unit-tested directly against `quote do ...
  end` input with no macro expansion. `Workflow.Schema.DSL` is the thin shell —
  its `schema … do … end` macro hands the raw do-block AST to `parse_object/2`,
  which walks the body as data (`field/2` dispatch delegating to `scalar_field/4`
  / `array_field/4`) and folds it through `object/1`. The identical path parses
  both the top-level body and every nested `array … of: :object do … end` body.

  ## The closed builder vocabulary

    * scalar leaves — `string`, `integer`, `number`, `boolean`
    * `array name, of: <scalar>` — a homogeneous list of scalars
    * `array name, of: :object do <fields> end` — a list of nested objects, whose
      body is parsed **recursively as data** (never executed as macros), so
      nesting works without a runtime builder stack or any closure.

  Every field is **required by default** (RubyLLM::Schema semantics); opt out with
  `required: false`. Anything outside this vocabulary — an unknown builder, a
  non-literal field name, a stray expression — **raises** a caller-located
  `Workflow.CompileError`, so a malformed schema fails `mix compile`, never at
  runtime. Determinism is a property of the vocabulary's shape: it can express only
  inert type structure, so a schema can carry no effect, closure, or randomness.
  """

  alias Workflow.CompileError
  alias Workflow.Compiler.Finding

  @scalar_types %{
    string: "string",
    integer: "integer",
    number: "number",
    boolean: "boolean"
  }

  @scalars Map.keys(@scalar_types)

  @doc "The closed set of scalar builder names in the vocabulary."
  @spec scalars() :: [atom()]
  def scalars, do: @scalars

  # --- Plain builders the DSL's field macros delegate to (unit-tested directly) ---

  @doc """
  Build a scalar field declaration `{key, json_map, required?}` from a literal
  field `name` and its `opts`. Raises (located at `env`) on a non-literal name or
  an unknown option.
  """
  @spec scalar_field(atom(), Macro.t(), Macro.t(), Macro.Env.t()) ::
          {String.t(), map(), boolean()}
  def scalar_field(type, name, opts, env) when type in @scalars do
    kw = keyword!(opts, [:required], env)
    {field_key(name, env), %{"type" => Map.fetch!(@scalar_types, type)}, required?(kw)}
  end

  @doc """
  Build an array field declaration `{key, json_map, required?}`. `of:` names the
  item type: a scalar (`of: :string`), or `:object` paired with a `block` (the
  nested do-block AST), whose fields are parsed recursively into the item schema.
  """
  @spec array_field(Macro.t(), Macro.t(), Macro.t() | nil, Macro.Env.t()) ::
          {String.t(), map(), boolean()}
  def array_field(name, opts, block, env) do
    kw = keyword!(opts, [:of, :required], env)
    key = field_key(name, env)
    {key, %{"type" => "array", "items" => array_items(kw, block, key, env)}, required?(kw)}
  end

  @doc """
  Assemble an object schema map from an ordered list of `{key, json, required?}`
  declarations. Property order follows declaration order; `required` lists exactly
  the required keys.
  """
  @spec object([{String.t(), map(), boolean()}]) :: map()
  def object(decls) do
    %{
      "type" => "object",
      "properties" => Map.new(decls, fn {key, json, _required} -> {key, json} end),
      "required" => for({key, _json, true} <- decls, do: key)
    }
  end

  @doc """
  Parse a do-block of builder forms into an object schema map. Used for the nested
  `array … of: :object do … end` body; walks the block as data and raises on any
  form outside the builder vocabulary.
  """
  @spec parse_object(Macro.t(), Macro.Env.t()) :: map()
  def parse_object(block, env) do
    block |> statements() |> Enum.map(&field(&1, env)) |> object()
  end

  # --- Item resolution for arrays ---

  defp array_items(kw, block, key, env) do
    case Keyword.fetch(kw, :of) do
      {:ok, :object} when block != nil ->
        parse_object(block, env)

      {:ok, :object} ->
        raise_finding(env, nil, "`array #{key}, of: :object` requires a `do` block",
          hint: ~s|array :#{key}, of: :object do string :field end|
        )

      {:ok, scalar} when scalar in @scalars and block == nil ->
        %{"type" => Map.fetch!(@scalar_types, scalar)}

      {:ok, scalar} when scalar in @scalars ->
        raise_finding(env, nil, "`array #{key}, of: :#{scalar}` does not take a `do` block")

      {:ok, other} ->
        raise_finding(env, nil, "`array #{key}` has an unknown item type #{inspect(other)}",
          hint: "of: one of :object, #{Enum.map_join(@scalars, ", ", &":#{&1}")}"
        )

      :error ->
        raise_finding(env, nil, "`array #{key}` requires an `of:` item type",
          hint: "e.g. array :#{key}, of: :string  or  array :#{key}, of: :object do … end"
        )
    end
  end

  # --- AST dispatch for a nested object body (raises on out-of-vocabulary) ---

  defp field({scalar, _meta, [name]}, env) when scalar in @scalars,
    do: scalar_field(scalar, name, [], env)

  defp field({scalar, _meta, [name, opts]}, env) when scalar in @scalars,
    do: scalar_field(scalar, name, opts, env)

  defp field({:array, _meta, [name, opts, [do: block]]}, env),
    do: array_field(name, opts, block, env)

  defp field({:array, _meta, [name, opts]}, env),
    do: array_field(name, opts, nil, env)

  defp field(form, env) do
    raise_finding(env, form, "unknown schema builder outside the field vocabulary",
      hint: "expected one of: #{vocabulary()}"
    )
  end

  # --- Shared literal helpers ---

  defp field_key(name, _env) when is_atom(name) and not is_nil(name), do: Atom.to_string(name)
  defp field_key(name, _env) when is_binary(name), do: name

  defp field_key(name, env) do
    raise_finding(env, name, "a schema field name must be a literal atom or string",
      hint: "e.g. string :file"
    )
  end

  defp keyword!(opts, allowed, env) when is_list(opts) do
    valid? =
      Enum.all?(opts, fn
        {key, _value} when is_atom(key) -> key in allowed
        _ -> false
      end)

    if valid? do
      opts
    else
      raise_finding(env, nil, "invalid schema field options",
        hint: "allowed options: #{Enum.map_join(allowed, ", ", &"#{&1}:")}"
      )
    end
  end

  defp keyword!(_opts, allowed, env) do
    raise_finding(env, nil, "schema field options must be a keyword list",
      hint: "allowed options: #{Enum.map_join(allowed, ", ", &"#{&1}:")}"
    )
  end

  defp required?(kw) do
    case Keyword.fetch(kw, :required) do
      :error -> true
      {:ok, bool} when is_boolean(bool) -> bool
      {:ok, _} -> raise CompileError, "`required:` must be a boolean"
    end
  end

  # A single-statement body is not wrapped in a __block__; an empty body is `nil`.
  defp statements({:__block__, _meta, stmts}), do: stmts
  defp statements(nil), do: []
  defp statements(single), do: [single]

  defp vocabulary do
    (Enum.map(@scalars, &Atom.to_string/1) ++ ["array"]) |> Enum.join(", ")
  end

  defp raise_finding(env, form, message, opts \\ []) do
    raise CompileError, Finding.format(Finding.at(env, form, message, opts))
  end
end
