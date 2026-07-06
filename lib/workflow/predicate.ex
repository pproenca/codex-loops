defmodule Workflow.Predicate do
  @moduledoc """
  The closed **predicate sub-vocabulary** a loop may test against journaled state.

  It is a tiny, total expression language parsed at compile time into inert structs
  and evaluated at runtime against a pure fold of the journal. The whole vocabulary
  is:

    * `count(:acc) >= n` — the size of a declared accumulator, compared to a literal
    * `budget_remaining() > n` — the ledger's remaining budget, compared to a literal
    * `all_of([...])` / `any_of([...])` — boolean combinators over nested predicates

  Comparison operators are `>`, `<`, `>=`, `<=`, `==`; the left operand must be
  `count(:acc)` or `budget_remaining()` and the right a literal integer. **Anything
  outside this set is rejected at compile time** — there is no arithmetic, no
  function call, no closure — so, like the workflow vocabulary itself, determinism
  is a property of what the grammar can and cannot express, not a runtime linter.

  Evaluation is a pure function over `%{accumulators: %{atom => list}, remaining:
  integer | :infinity}`. `:infinity` compares correctly with `>`/`>=` because an
  atom sorts above every integer in Erlang term order, matching the ledger.
  """

  alias Workflow.Compiler.Finding

  defmodule Count do
    @moduledoc "The size of a declared accumulator — the left operand of a compare."
    @enforce_keys [:acc]
    defstruct [:acc]
    @type t :: %__MODULE__{acc: atom()}
  end

  defmodule BudgetRemaining do
    @moduledoc "The ledger's remaining budget — the left operand of a compare."
    defstruct []
    @type t :: %__MODULE__{}
  end

  defmodule Compare do
    @moduledoc "A comparison of an operand against a literal integer threshold."
    @enforce_keys [:op, :left, :right]
    defstruct [:op, :left, :right]
    @type t :: %__MODULE__{op: atom(), left: struct(), right: integer()}
  end

  defmodule AllOf do
    @moduledoc "True when every nested predicate is true."
    @enforce_keys [:predicates]
    defstruct [:predicates]
    @type t :: %__MODULE__{predicates: [struct()]}
  end

  defmodule AnyOf do
    @moduledoc "True when any nested predicate is true."
    @enforce_keys [:predicates]
    defstruct [:predicates]
    @type t :: %__MODULE__{predicates: [struct()]}
  end

  @comparisons [:>, :<, :>=, :<=, :==]

  @type t :: Compare.t() | AllOf.t() | AnyOf.t()
  @type context :: %{accumulators: %{atom() => list()}, remaining: integer() | :infinity}

  # --- Compile-time parsing (returns a located Finding on any out-of-vocab form) ---

  @doc """
  Parse a quoted predicate into an inert struct, or a located `{:error, %Finding{}}`
  for anything outside the closed sub-vocabulary.
  """
  @spec parse(Macro.t(), Macro.Env.t()) :: {:ok, t()} | {:error, Finding.t()}
  def parse(ast, env), do: predicate(ast, env)

  defp predicate({op, _meta, [left, right]} = form, env) when op in @comparisons do
    with {:ok, operand} <- operand(left, form, env),
         {:ok, threshold} <- threshold(right, form, env) do
      {:ok, %Compare{op: op, left: operand, right: threshold}}
    end
  end

  defp predicate({:all_of, _meta, [branches]} = form, env) when is_list(branches),
    do: combine(AllOf, branches, form, env)

  defp predicate({:any_of, _meta, [branches]} = form, env) when is_list(branches),
    do: combine(AnyOf, branches, form, env)

  defp predicate(form, env) do
    {:error,
     Finding.at(env, form, "unsupported predicate",
       hint: "the predicate vocabulary is: #{vocabulary()}"
     )}
  end

  defp combine(module, branches, form, env) do
    branches
    |> Enum.reduce_while({:ok, []}, fn branch, {:ok, acc} ->
      case predicate(branch, env) do
        {:ok, pred} -> {:cont, {:ok, [pred | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, []} ->
        {:error, Finding.at(env, form, "`#{combinator(module)}` requires at least one predicate")}

      {:ok, preds} ->
        {:ok, struct!(module, predicates: Enum.reverse(preds))}

      err ->
        err
    end
  end

  defp operand({:count, _meta, [acc]}, _form, _env) when is_atom(acc), do: {:ok, %Count{acc: acc}}
  defp operand({:budget_remaining, _meta, []}, _form, _env), do: {:ok, %BudgetRemaining{}}

  defp operand(_other, form, env) do
    {:error,
     Finding.at(env, form, "unsupported predicate operand",
       hint: "the left side must be `count(:acc)` or `budget_remaining()`"
     )}
  end

  defp threshold(n, _form, _env) when is_integer(n), do: {:ok, n}

  defp threshold(_other, form, env),
    do: {:error, Finding.at(env, form, "a predicate threshold must be a literal integer")}

  defp combinator(AllOf), do: "all_of"
  defp combinator(AnyOf), do: "any_of"

  defp vocabulary,
    do: "count(:acc) >= n, budget_remaining() > n, all_of([...]), any_of([...])"

  # --- Runtime evaluation (pure over a journal-folded context) ---

  @doc "Evaluate a parsed predicate against a folded journal context."
  @spec evaluate(t(), context()) :: boolean()
  def evaluate(%Compare{op: op, left: left, right: right}, ctx),
    do: compare(op, resolve(left, ctx), right)

  def evaluate(%AllOf{predicates: preds}, ctx), do: Enum.all?(preds, &evaluate(&1, ctx))
  def evaluate(%AnyOf{predicates: preds}, ctx), do: Enum.any?(preds, &evaluate(&1, ctx))

  defp resolve(%Count{acc: acc}, ctx), do: length(Map.get(ctx.accumulators, acc, []))
  defp resolve(%BudgetRemaining{}, ctx), do: ctx.remaining

  defp compare(:>, a, b), do: a > b
  defp compare(:<, a, b), do: a < b
  defp compare(:>=, a, b), do: a >= b
  defp compare(:<=, a, b), do: a <= b
  defp compare(:==, a, b), do: a == b
end
