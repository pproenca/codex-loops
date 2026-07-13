defmodule Workflow.Predicate do
  @moduledoc """
  The closed **predicate sub-vocabulary** a loop may test against journaled state.

  It is a tiny, total expression language parsed at compile time into inert structs
  and evaluated at runtime against a pure fold of the journal. The vocabulary is
  closed: predicates may read only accumulators, ledger state, dry-streak state,
  and explicitly resolved binding refs.

  Comparison operators are `>`, `<`, `>=`, `<=`, `==`; the left operand must be
  `count(:acc)`, `budget_remaining()`, or `path_count(:binding, "/pointer")`,
  and the right operand must be a literal integer. Boolean combinators are
  `all([...])` and `any([...])`; legacy `all_of([...])` and `any_of([...])`
  remain aliases.
  """

  alias Workflow.Compiler.Finding
  alias Workflow.JSONPointer
  alias Workflow.JSONValue

  defmodule Count do
    @moduledoc "The size of a declared accumulator -- the left operand of a compare."
    @enforce_keys [:acc]
    defstruct [:acc]
    @type t :: %__MODULE__{acc: atom()}
  end

  defmodule BudgetRemaining do
    @moduledoc "The ledger's remaining budget -- the left operand of a compare."
    defstruct []
    @type t :: %__MODULE__{}
  end

  defmodule PathCount do
    @moduledoc "The count of a JSON Pointer lookup under a resolved binding ref."
    @enforce_keys [:binding, :ref, :pointer]
    defstruct [:binding, :ref, :pointer]
    @type t :: %__MODULE__{binding: atom(), ref: Workflow.Node.binding_ref(), pointer: String.t()}
  end

  defmodule Compare do
    @moduledoc "A comparison of an operand against a literal integer threshold."
    @enforce_keys [:op, :left, :right]
    defstruct [:op, :left, :right]

    @type t :: %__MODULE__{
            op: atom(),
            left: Count.t() | BudgetRemaining.t() | PathCount.t(),
            right: integer()
          }
  end

  defmodule Dry do
    @moduledoc "True when the folded loop dry streak is at least `rounds`."
    @enforce_keys [:rounds, :seen_by]
    defstruct [:rounds, :seen_by]
    @type t :: %__MODULE__{rounds: pos_integer(), seen_by: [atom()]}
  end

  defmodule PathExists do
    @moduledoc "True when a JSON Pointer lookup is present, including present nil."
    @enforce_keys [:binding, :ref, :pointer]
    defstruct [:binding, :ref, :pointer]
    @type t :: %__MODULE__{binding: atom(), ref: Workflow.Node.binding_ref(), pointer: String.t()}
  end

  defmodule PathNonEmpty do
    @moduledoc "True when a JSON Pointer lookup resolves to a non-empty value."
    @enforce_keys [:binding, :ref, :pointer]
    defstruct [:binding, :ref, :pointer]
    @type t :: %__MODULE__{binding: atom(), ref: Workflow.Node.binding_ref(), pointer: String.t()}
  end

  defmodule PathEquals do
    @moduledoc "True when a JSON Pointer lookup is JSON-equal to a literal."
    @enforce_keys [:binding, :ref, :pointer, :literal]
    defstruct [:binding, :ref, :pointer, :literal]

    @type t :: %__MODULE__{
            binding: atom(),
            ref: Workflow.Node.binding_ref(),
            pointer: String.t(),
            literal: term()
          }
  end

  defmodule Agree do
    @moduledoc "True when a bound list has enough JSON-equal values at a pointer."
    @enforce_keys [:binding, :ref, :pointer, :literal, :threshold]
    defstruct [:binding, :ref, :pointer, :literal, :threshold]

    @type threshold :: :all | :any | pos_integer()
    @type t :: %__MODULE__{
            binding: atom(),
            ref: Workflow.Node.binding_ref(),
            pointer: String.t(),
            literal: term(),
            threshold: threshold()
          }
  end

  defmodule AllOf do
    @moduledoc "True when every nested predicate is true."
    @enforce_keys [:predicates]
    defstruct [:predicates]
    @type t :: %__MODULE__{predicates: [Workflow.Predicate.t()]}
  end

  defmodule AnyOf do
    @moduledoc "True when any nested predicate is true."
    @enforce_keys [:predicates]
    defstruct [:predicates]
    @type t :: %__MODULE__{predicates: [Workflow.Predicate.t()]}
  end

  defmodule Context do
    @moduledoc "The complete journal-folded state available to runtime predicates."
    @enforce_keys [:accumulators, :remaining, :dry_streak, :bindings]
    defstruct [:accumulators, :remaining, :dry_streak, :bindings]

    @type t :: %__MODULE__{
            accumulators: %{atom() => list()},
            remaining: integer() | :infinity,
            dry_streak: non_neg_integer(),
            bindings: %{Workflow.Node.binding_ref() => term()}
          }
  end

  @comparisons [:>, :<, :>=, :<=, :==]
  @binding_ref_kinds [:node, :map, :refine]

  @type t ::
          Compare.t()
          | Dry.t()
          | PathExists.t()
          | PathNonEmpty.t()
          | PathEquals.t()
          | Agree.t()
          | AllOf.t()
          | AnyOf.t()

  @type binding_env :: %{atom() => Workflow.Node.binding_ref()}

  # --- Compile-time parsing (returns a located Finding on any out-of-vocab form) ---

  @doc """
  Parse a quoted predicate into an inert struct, or a located `{:error, %Finding{}}`
  for anything outside the closed sub-vocabulary.

  `parse/2` preserves the legacy call shape and has no binding refs in scope.
  Use `parse/3` when path/agreement predicates may reference lexically preceding
  bindings.
  """
  @spec parse(Macro.t(), Macro.Env.t()) :: {:ok, t()} | {:error, Finding.t()}
  def parse(ast, env), do: parse(ast, env, %{})

  @spec parse(Macro.t(), Macro.Env.t(), binding_env()) :: {:ok, t()} | {:error, Finding.t()}
  def parse(ast, env, binding_env) when is_map(binding_env), do: predicate(ast, env, binding_env)

  @doc """
  Return the shared `seen_by` list required by any `dry(...)` predicates in a tree.

  A predicate tree with no `dry(...)` predicates returns `{:ok, []}`. Multiple dry
  predicates may omit `seen_by` or use the same list; conflicting lists are a
  compile-time validation error for loop callers.
  """
  @spec dry_seen_by(t() | nil) :: {:ok, [atom()]} | {:error, :conflicting_seen_by}
  def dry_seen_by(predicate) do
    case dry_seen_by_value(predicate) do
      {:ok, nil} -> {:ok, []}
      {:ok, seen_by} -> {:ok, seen_by}
      {:error, :conflicting_seen_by} = error -> error
    end
  end

  @doc "Return every journal binding ref read by a parsed predicate."
  @spec binding_refs(t()) :: [Workflow.Node.binding_ref()]
  def binding_refs(%Compare{left: %PathCount{ref: ref}}), do: [ref]
  def binding_refs(%Compare{left: %Count{}}), do: []
  def binding_refs(%Compare{left: %BudgetRemaining{}}), do: []
  def binding_refs(%Dry{}), do: []
  def binding_refs(%PathExists{ref: ref}), do: [ref]
  def binding_refs(%PathNonEmpty{ref: ref}), do: [ref]
  def binding_refs(%PathEquals{ref: ref}), do: [ref]
  def binding_refs(%Agree{ref: ref}), do: [ref]
  def binding_refs(%AllOf{predicates: predicates}), do: Enum.flat_map(predicates, &binding_refs/1)
  def binding_refs(%AnyOf{predicates: predicates}), do: Enum.flat_map(predicates, &binding_refs/1)

  defp predicate({op, _meta, [left, right]} = form, env, binding_env) when op in @comparisons do
    with {:ok, operand} <- operand(left, form, env, binding_env),
         {:ok, threshold} <- threshold(right, form, env) do
      {:ok, %Compare{op: op, left: operand, right: threshold}}
    end
  end

  defp predicate({name, _meta, [branches]} = form, env, binding_env) when name in [:all, :all_of] and is_list(branches),
    do: combine(AllOf, name, branches, form, env, binding_env)

  defp predicate({name, _meta, [branches]} = form, env, binding_env) when name in [:any, :any_of] and is_list(branches),
    do: combine(AnyOf, name, branches, form, env, binding_env)

  defp predicate({:dry, _meta, [opts]} = form, env, _binding_env) when is_list(opts), do: dry(opts, form, env)

  defp predicate({:path_exists, _meta, [binding, pointer]} = form, env, binding_env),
    do: path_predicate(PathExists, binding, pointer, form, env, binding_env)

  defp predicate({:path_non_empty, _meta, [binding, pointer]} = form, env, binding_env),
    do: path_predicate(PathNonEmpty, binding, pointer, form, env, binding_env)

  defp predicate({:path_equals, _meta, [binding, pointer, literal]} = form, env, binding_env) do
    with {:ok, binding, ref} <- binding_ref(binding, form, env, binding_env),
         {:ok, pointer} <- json_pointer(pointer, form, env),
         {:ok, literal} <- literal_to_json(literal, form, env) do
      {:ok, %PathEquals{binding: binding, ref: ref, pointer: pointer, literal: literal}}
    end
  end

  defp predicate({:agree, _meta, [binding, opts]} = form, env, binding_env) when is_list(opts) do
    with {:ok, opts} <-
           exact_keyword(
             opts,
             [:path, :equals, :threshold],
             [:path, :equals, :threshold],
             form,
             env,
             "`agree`"
           ),
         {:ok, binding, ref} <- binding_ref(binding, form, env, binding_env),
         {:ok, pointer} <- json_pointer(Keyword.fetch!(opts, :path), form, env),
         {:ok, literal} <- literal_to_json(Keyword.fetch!(opts, :equals), form, env),
         {:ok, threshold} <- agreement_threshold(Keyword.fetch!(opts, :threshold), form, env) do
      {:ok,
       %Agree{
         binding: binding,
         ref: ref,
         pointer: pointer,
         literal: literal,
         threshold: threshold
       }}
    end
  end

  defp predicate(form, env, _binding_env) do
    {:error, Finding.at(env, form, "unsupported predicate", hint: "the predicate vocabulary is: #{vocabulary()}")}
  end

  defp combine(module, name, branches, form, env, binding_env) do
    branches
    |> Enum.reduce_while({:ok, []}, fn branch, {:ok, acc} ->
      case predicate(branch, env, binding_env) do
        {:ok, pred} -> {:cont, {:ok, [pred | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, []} ->
        {:error, Finding.at(env, form, "`#{name}` requires at least one predicate")}

      {:ok, preds} ->
        {:ok, struct!(module, predicates: Enum.reverse(preds))}

      err ->
        err
    end
  end

  defp dry(opts, form, env) do
    with {:ok, opts} <- exact_keyword(opts, [:rounds, :seen_by], [:rounds], form, env, "`dry`"),
         {:ok, rounds} <- positive_integer(Keyword.fetch!(opts, :rounds), :rounds, form, env),
         {:ok, seen_by} <- seen_by(Keyword.get(opts, :seen_by, []), form, env) do
      {:ok, %Dry{rounds: rounds, seen_by: seen_by}}
    end
  end

  defp path_predicate(module, binding, pointer, form, env, binding_env) do
    with {:ok, binding, ref} <- binding_ref(binding, form, env, binding_env),
         {:ok, pointer} <- json_pointer(pointer, form, env) do
      {:ok, struct!(module, binding: binding, ref: ref, pointer: pointer)}
    end
  end

  defp operand({:count, _meta, [acc]}, _form, _env, _binding_env)
       when is_atom(acc) and not is_boolean(acc) and not is_nil(acc), do: {:ok, %Count{acc: acc}}

  defp operand({:budget_remaining, _meta, []}, _form, _env, _binding_env), do: {:ok, %BudgetRemaining{}}

  defp operand({:path_count, _meta, [binding, pointer]} = form, _outer_form, env, binding_env) do
    with {:ok, binding, ref} <- binding_ref(binding, form, env, binding_env),
         {:ok, pointer} <- json_pointer(pointer, form, env) do
      {:ok, %PathCount{binding: binding, ref: ref, pointer: pointer}}
    end
  end

  defp operand(_other, form, env, _binding_env) do
    {:error,
     Finding.at(env, form, "unsupported predicate operand",
       hint: "the left side must be `count(:acc)`, `budget_remaining()`, or `path_count(:binding, \"/pointer\")`"
     )}
  end

  defp threshold(n, _form, _env) when is_integer(n), do: {:ok, n}

  defp threshold(_other, form, env),
    do: {:error, Finding.at(env, form, "a predicate threshold must be a literal integer")}

  defp exact_keyword(opts, allowed, required, form, env, label) do
    keys = if Keyword.keyword?(opts), do: Keyword.keys(opts), else: []
    duplicates = keys -- Enum.uniq(keys)

    cond do
      not Keyword.keyword?(opts) ->
        {:error, Finding.at(env, form, "#{label} options must be a keyword list")}

      duplicates != [] ->
        {:error, Finding.at(env, form, "#{label} has duplicate option #{inspect(hd(duplicates))}")}

      Enum.any?(keys, &(&1 not in allowed)) or Enum.any?(required, &(&1 not in keys)) ->
        {:error, Finding.at(env, form, "invalid #{label} options", hint: "allowed options: #{Enum.join(allowed, ", ")}")}

      true ->
        {:ok, opts}
    end
  end

  defp positive_integer(n, _key, _form, _env) when is_integer(n) and n >= 1, do: {:ok, n}

  defp positive_integer(_value, key, form, env), do: {:error, Finding.at(env, form, "`#{key}` must be an integer >= 1")}

  defp seen_by(fields, form, env) when is_list(fields) do
    if Enum.all?(fields, &field_atom?/1) do
      {:ok, fields}
    else
      {:error, Finding.at(env, form, "`dry` `seen_by:` must be a list of field atoms")}
    end
  end

  defp seen_by(_fields, form, env), do: {:error, Finding.at(env, form, "`dry` `seen_by:` must be a list of field atoms")}

  defp field_atom?(field), do: is_atom(field) and not is_boolean(field) and not is_nil(field)

  defp binding_ref(binding, form, env, binding_env)
       when is_atom(binding) and not is_boolean(binding) and not is_nil(binding) do
    case Map.fetch(binding_env, binding) do
      {:ok, ref} ->
        if binding_ref?(ref) do
          {:ok, binding, ref}
        else
          {:error,
           Finding.at(
             env,
             form,
             "binding #{inspect(binding)} does not resolve to a journal binding ref"
           )}
        end

      :error ->
        {:error, Finding.at(env, form, "unknown binding #{inspect(binding)}")}
    end
  end

  defp binding_ref(_binding, form, env, _binding_env) do
    {:error, Finding.at(env, form, "predicate binding must be a literal binding atom")}
  end

  defp binding_ref?({kind, address}) when kind in @binding_ref_kinds and is_list(address),
    do: Enum.all?(address, &(is_integer(&1) and &1 >= 0))

  defp binding_ref?({:fanout, address, :global}) when is_list(address),
    do: Enum.all?(address, &(is_integer(&1) and &1 >= 0))

  defp binding_ref?({:fanout, address, {:loop_local, loop_address}}) when is_list(address) and is_list(loop_address),
    do: Enum.all?(address, &(is_integer(&1) and &1 >= 0)) and Enum.all?(loop_address, &(is_integer(&1) and &1 >= 0))

  defp binding_ref?(_ref), do: false

  defp json_pointer(pointer, form, env) when is_binary(pointer) do
    if JSONPointer.valid?(pointer) do
      {:ok, :binary.copy(pointer)}
    else
      {:error,
       Finding.at(
         env,
         form,
         ~s(predicate JSON pointer must be "" or start with "/" and use RFC 6901 escapes)
       )}
    end
  end

  defp json_pointer(_pointer, form, env),
    do: {:error, Finding.at(env, form, "predicate JSON pointer must be a literal string")}

  defp literal_to_json(value, form, env) do
    value
    |> JSONValue.from_literal(:finite_floats)
    |> literal_error(form, env)
  end

  defp literal_error({:ok, _value} = result, _form, _env), do: result

  defp literal_error({:error, :duplicate_key}, form, env),
    do: {:error, Finding.at(env, form, "predicate literal has duplicate object key")}

  defp literal_error({:error, :invalid_key}, form, env),
    do: {:error, Finding.at(env, form, "predicate literal object keys must be strings or atoms")}

  defp literal_error({:error, :non_finite_float}, form, env),
    do: {:error, Finding.at(env, form, "predicate literal floats must be finite")}

  defp literal_error({:error, _reason}, form, env),
    do: {:error, Finding.at(env, form, "predicate literal is not JSON-encodable")}

  defp agreement_threshold(threshold, _form, _env) when threshold in [:all, :any], do: {:ok, threshold}

  defp agreement_threshold(threshold, _form, _env) when is_integer(threshold) and threshold >= 1, do: {:ok, threshold}

  defp agreement_threshold(_threshold, form, env) do
    {:error, Finding.at(env, form, "`agree` threshold must be :all, :any, or a positive integer")}
  end

  defp vocabulary do
    "count(:acc) >= n, budget_remaining() > n, path_count(:binding, \"/pointer\") == n, " <>
      "dry(rounds: n), agree(:binding, path: \"/pointer\", equals: literal, threshold: :all), " <>
      ~s{path_exists(:binding, "/pointer"), path_non_empty(:binding, "/pointer"), } <>
      "path_equals(:binding, \"/pointer\", literal), all([...]), any([...])"
  end

  defp dry_seen_by_value(nil), do: {:ok, nil}
  defp dry_seen_by_value(%Dry{seen_by: seen_by}), do: {:ok, seen_by}
  defp dry_seen_by_value(%AllOf{predicates: predicates}), do: dry_seen_by_values(predicates)
  defp dry_seen_by_value(%AnyOf{predicates: predicates}), do: dry_seen_by_values(predicates)
  defp dry_seen_by_value(_predicate), do: {:ok, nil}

  defp dry_seen_by_values(predicates) do
    Enum.reduce_while(predicates, {:ok, nil}, fn predicate, {:ok, acc} ->
      case dry_seen_by_value(predicate) do
        {:ok, nil} ->
          {:cont, {:ok, acc}}

        {:ok, seen_by} when is_nil(acc) or acc == seen_by ->
          {:cont, {:ok, seen_by}}

        {:ok, _conflicting_seen_by} ->
          {:halt, {:error, :conflicting_seen_by}}

        {:error, :conflicting_seen_by} = error ->
          {:halt, error}
      end
    end)
  end

  # --- Runtime evaluation (pure over a journal-folded context) ---

  @doc "Evaluate a parsed predicate against a folded journal context."
  @spec evaluate(t(), Context.t()) :: boolean()
  def evaluate(%Compare{op: op, left: left, right: right}, ctx), do: compare(op, resolve(left, ctx), right)

  def evaluate(%Dry{rounds: rounds}, %Context{dry_streak: dry_streak}), do: dry_streak >= rounds

  def evaluate(%PathExists{ref: ref, pointer: pointer}, ctx),
    do: match?({:present, _value}, resolve_path(resolve_ref(ref, ctx), pointer))

  def evaluate(%PathNonEmpty{ref: ref, pointer: pointer}, ctx),
    do: ref |> resolve_ref(ctx) |> resolve_path(pointer) |> path_non_empty?()

  def evaluate(%PathEquals{ref: ref, pointer: pointer, literal: literal}, ctx) do
    case ref |> resolve_ref(ctx) |> resolve_path(pointer) do
      {:present, value} -> JSONValue.equal?(value, literal)
      :missing -> false
    end
  end

  def evaluate(%Agree{ref: ref, pointer: pointer, literal: literal, threshold: threshold}, ctx),
    do: agree?(resolve_ref(ref, ctx), pointer, literal, threshold)

  def evaluate(%AllOf{predicates: preds}, ctx), do: Enum.all?(preds, &evaluate(&1, ctx))
  def evaluate(%AnyOf{predicates: preds}, ctx), do: Enum.any?(preds, &evaluate(&1, ctx))

  defp resolve(%Count{acc: acc}, %Context{accumulators: accumulators}), do: accumulators |> Map.get(acc, []) |> length()

  defp resolve(%BudgetRemaining{}, %Context{remaining: remaining}), do: remaining

  defp resolve(%PathCount{ref: ref, pointer: pointer}, ctx),
    do: ref |> resolve_ref(ctx) |> resolve_path(pointer) |> JSONValue.count_resolution()

  defp resolve_ref(ref, %Context{bindings: bindings}) do
    case Map.fetch(bindings, ref) do
      {:ok, value} -> value
      :error -> :missing
    end
  end

  defp compare(:>, a, b), do: a > b
  defp compare(:<, a, b), do: a < b
  defp compare(:>=, a, b), do: a >= b
  defp compare(:<=, a, b), do: a <= b
  defp compare(:==, a, b), do: a == b

  defp resolve_path(:missing, _pointer), do: :missing
  defp resolve_path(value, pointer), do: JSONPointer.resolve(value, pointer)

  defp path_non_empty?(resolution), do: JSONValue.non_empty_resolution?(resolution)

  defp agree?(value, pointer, literal, threshold) when is_list(value) do
    value_count = length(value)

    matches =
      Enum.count(value, fn item ->
        case JSONPointer.resolve(item, pointer) do
          {:present, candidate} -> JSONValue.equal?(candidate, literal)
          :missing -> false
        end
      end)

    case threshold do
      :all -> matches == value_count and value_count > 0
      :any -> matches >= 1
      n when is_integer(n) -> matches >= n
    end
  end

  defp agree?(_value, _pointer, _literal, _threshold), do: false
end
