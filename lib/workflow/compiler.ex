defmodule Workflow.Compiler do
  @moduledoc """
  Turns a quoted workflow body into an inert `%Workflow.Tree{}` at compile time.

  This is the whole DSL. It is a plain function — deliberately *not* a macro — so
  it can be unit-tested directly against `quote do ... end` input with no macro
  expansion, and so all parsing/validation lives in one testable place. The
  `workflow/2` macro is a thin shell that calls this and escapes the result.

  ## Failure modes

  Determinism is enforced by the **absence of vocabulary nodes plus compiler
  rejection**, never a runtime linter. There is no node for randomness or
  wall-clock, so a workflow cannot express them; the forbidden-form catalog below
  makes the escape hatches unrepresentable too. Every diagnostic is
  caller-located: it cites the user's `file:line` taken from the offending form's
  AST metadata.

    * **Outside the vocabulary** — a closure (`fn -> ... end`), a call to any
      external module (`:rand.*`, `System.*`, `Enum.*`, ...), an unknown bare call,
      or a stray literal/variable — **raises** `Workflow.CompileError`. Unknown
      combinators carry a closed-vocabulary suggestion ("did you mean ...").
    * **A known combinator with the wrong argument shape** (per-node option error)
      returns `{:error, %Finding{}}` located at the declaration site.
    * **Whole-DSL invariants** — duplicate phase names, a workflow with no
      `return` — return `{:error, %Finding{}}` located at the offending
      declaration (or the workflow itself, for a missing `return`).

  The `workflow/2` macro turns any `{:error, finding}` into a raised, formatted
  `Workflow.CompileError`, so both channels surface as a located `mix compile`
  failure.
  """

  alias Workflow.Tree
  alias Workflow.Node.{Phase, Log, Agent, Return}
  alias Workflow.Compiler.Finding

  # The closed combinator vocabulary. Determinism is a property of this set: it
  # contains no randomness or wall-clock node, so neither can be expressed.
  @combinators [:agent, :log, :phase, :return]

  @spec parse(Macro.t(), Macro.Env.t()) :: {:ok, Tree.t()} | {:error, Finding.t()}
  def parse(block, env) do
    with {:ok, nodes} <- build(statements(block), 0, [], MapSet.new(), env),
         :ok <- validate_tree(nodes, env) do
      {:ok, %Tree{nodes: nodes}}
    end
  end

  # A single-statement body is not wrapped in a __block__.
  defp statements({:__block__, _meta, stmts}), do: stmts
  defp statements(nil), do: []
  defp statements(single), do: [single]

  # --- Per-statement build (per-node option errors located at the call site) ---

  defp build([], _index, acc, _seen, _env), do: {:ok, Enum.reverse(acc)}

  defp build([stmt | rest], index, acc, seen, env) do
    case node(stmt, [index], env) do
      {:ok, %Phase{name: name} = phase} ->
        if MapSet.member?(seen, name) do
          {:error,
           Finding.at(env, stmt, "duplicate phase name #{inspect(name)}",
             hint: "phase names must be unique within a workflow"
           )}
        else
          build(rest, index + 1, [phase | acc], MapSet.put(seen, name), env)
        end

      {:ok, node} ->
        build(rest, index + 1, [node | acc], seen, env)

      {:error, finding} ->
        {:error, finding}
    end
  end

  # --- The closed combinator vocabulary ---

  defp node({:phase, _meta, [name]}, address, _env) when is_binary(name),
    do: {:ok, %Phase{address: address, name: name}}

  defp node({:log, _meta, [message]}, address, _env) when is_binary(message),
    do: {:ok, %Log{address: address, message: message}}

  defp node({:agent, _meta, [prompt]}, address, _env) when is_binary(prompt),
    do: {:ok, %Agent{address: address, prompt: prompt}}

  defp node({:return, _meta, [value]} = form, address, env) do
    if Macro.quoted_literal?(value) do
      {:ok, %Return{address: address, value: value}}
    else
      {:error,
       Finding.at(env, form, "`return` expects a literal value",
         hint: "return only compile-time constants; a workflow cannot compute at runtime"
       )}
    end
  end

  # A known combinator invoked with the wrong argument shape: recoverable finding,
  # located at the declaration site.
  defp node({combinator, _meta, _args} = form, _address, env)
       when combinator in @combinators,
       do: {:error, Finding.at(env, form, "`#{combinator}` was called with invalid arguments")}

  # --- Forbidden-form catalog: everything below raises, so non-determinism and
  # escape hatches are unrepresentable in a compiled tree. ---

  # Anonymous functions destroy total-validation, serialization, and resume.
  defp node({:fn, _meta, _clauses} = form, _address, env) do
    raise_finding(
      Finding.at(env, form, "anonymous functions are not part of the workflow vocabulary",
        hint: "a workflow is inert, serializable data — it cannot capture a closure"
      )
    )
  end

  # Any call into an external module — `:rand.*`, `System.*`, `Enum.*`, ... .
  defp node({{:., _, [_module, _fun]}, _meta, _args} = form, _address, env) do
    raise_finding(
      Finding.at(env, form, "calls to external modules are not part of the workflow vocabulary",
        hint: "a workflow must be deterministic and self-contained (no #{callee(form)})"
      )
    )
  end

  # An unknown bare call: reject with a closed-vocabulary suggestion.
  defp node({name, _meta, args} = form, _address, env)
       when is_atom(name) and is_list(args) do
    raise_finding(Finding.at(env, form, "unknown combinator `#{name}`", hint: suggest(name)))
  end

  # Anything else — a stray literal, a variable, an operator: outside the vocabulary.
  defp node(form, _address, env) do
    raise_finding(
      Finding.at(env, form, "unknown workflow form outside the combinator vocabulary",
        hint: "expected one of: #{vocabulary()}"
      )
    )
  end

  # --- Whole-DSL invariants ---

  defp validate_tree(nodes, env) do
    if Enum.any?(nodes, &match?(%Return{}, &1)) do
      :ok
    else
      {:error,
       Finding.at(env, nil, "workflow must contain a `return`",
         hint: "add a `return <literal>` so the run terminates with a value"
       )}
    end
  end

  # --- Suggestions from the closed vocabulary ---

  defp suggest(name) do
    typed = Atom.to_string(name)

    {best, score} =
      @combinators
      |> Enum.map(&{&1, String.jaro_distance(typed, Atom.to_string(&1))})
      |> Enum.max_by(&elem(&1, 1))

    if score >= 0.7 do
      "did you mean `#{best}`? (expected one of: #{vocabulary()})"
    else
      "expected one of: #{vocabulary()}"
    end
  end

  defp vocabulary, do: @combinators |> Enum.map(&Atom.to_string/1) |> Enum.join(", ")

  defp callee({{:., _, [module, fun]}, _, _}), do: "#{Macro.to_string(module)}.#{fun}"

  defp raise_finding(%Finding{} = finding),
    do: raise(Workflow.CompileError, Finding.format(finding))
end
