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
  alias Workflow.Node.{Phase, Log, Agent, Return, Parallel, Pipeline}
  alias Workflow.Compiler.Finding

  # The closed combinator vocabulary. Determinism is a property of this set: it
  # contains no randomness or wall-clock node, so neither can be expressed.
  @combinators [:agent, :log, :phase, :parallel, :pipeline, :return]

  # Options a schema-backed `agent` accepts, and the default retry budget when
  # `retries:` is omitted (total attempts = retries + 1).
  @agent_option_keys [:schema, :retries]
  @default_retries 2

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
    do: {:ok, %Agent{address: address, prompt: prompt, schema: nil, retries: @default_retries}}

  # A schema-backed agent: `agent "…", schema: %{…}, retries: n`. The options must
  # be a literal keyword list drawn from @agent_option_keys; the schema must be a
  # literal map (materialized to its runtime value so the node stays inert data).
  defp node({:agent, _meta, [prompt, opts]} = form, address, env) when is_binary(prompt) do
    with {:ok, kw} <- agent_options(opts, form, env),
         {:ok, schema} <- agent_schema(kw, form, env),
         {:ok, retries} <- agent_retries(kw, form, env) do
      {:ok, %Agent{address: address, prompt: prompt, schema: schema, retries: retries}}
    end
  end

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

  # `parallel [agent(...), ...]` — a barrier fan-out over a literal list of agent
  # branches, optionally capped by `max_concurrency:`. Each branch is addressed
  # `address ++ [branch_index]`, so branches journal and key independently.
  defp node({:parallel, _meta, [branches]} = form, address, env) when is_list(branches),
    do: parallel(branches, [], address, form, env)

  defp node({:parallel, _meta, [branches, opts]} = form, address, env) when is_list(branches),
    do: parallel(branches, opts, address, form, env)

  # `pipeline items, [agent(...), ...]` — per-item lanes through ordered stages,
  # optionally capped by `max_concurrency:`. `items` is a literal list; the lanes
  # are expanded here into pre-addressed inert agents.
  defp node({:pipeline, _meta, [items, stages]} = form, address, env),
    do: pipeline(items, stages, [], address, form, env)

  defp node({:pipeline, _meta, [items, stages, opts]} = form, address, env),
    do: pipeline(items, stages, opts, address, form, env)

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

  # --- Schema-backed agent options (per-node findings, located at the call) ---

  defp agent_options(opts, form, env) do
    if keyword_literal?(opts) and Enum.all?(opts, fn {k, _} -> k in @agent_option_keys end) do
      {:ok, opts}
    else
      {:error,
       Finding.at(env, form, "`agent` was called with invalid arguments",
         hint: "agent options are a keyword list of: #{Enum.join(@agent_option_keys, ", ")}"
       )}
    end
  end

  defp keyword_literal?(list) when is_list(list) do
    Enum.all?(list, fn
      {key, _value} when is_atom(key) -> true
      _ -> false
    end)
  end

  defp keyword_literal?(_), do: false

  defp agent_schema(kw, form, env) do
    case Keyword.fetch(kw, :schema) do
      {:ok, {:%{}, _, _} = ast} ->
        if Macro.quoted_literal?(ast) do
          {:ok, materialize(ast)}
        else
          {:error, schema_finding(form, env)}
        end

      {:ok, _not_a_map_literal} ->
        {:error, schema_finding(form, env)}

      :error ->
        {:error,
         Finding.at(env, form, "`agent` with options requires a `schema:`",
           hint: "schema-backed agents fail closed; give schema: %{...}"
         )}
    end
  end

  defp schema_finding(form, env) do
    Finding.at(env, form, "`agent` schema must be a literal map",
      hint: ~s|pass a raw JSON-schema map literal, e.g. schema: %{"type" => "object"}|
    )
  end

  defp agent_retries(kw, form, env) do
    case Keyword.fetch(kw, :retries) do
      :error -> {:ok, @default_retries}
      {:ok, n} when is_integer(n) and n >= 0 -> {:ok, n}
      {:ok, _} -> {:error, Finding.at(env, form, "`agent` retries must be a non-negative integer")}
    end
  end

  # --- Static fan-out combinators (parallel / pipeline) ---

  defp parallel([], _opts, _address, form, env) do
    {:error,
     Finding.at(env, form, "`parallel` requires at least one branch",
       hint: "parallel [agent(\"...\"), agent(\"...\")]"
     )}
  end

  defp parallel(branches, opts, address, form, env) do
    with {:ok, cap} <- concurrency_opt(opts, form, env),
         {:ok, nodes} <- agent_branches(branches, address, env) do
      {:ok, %Parallel{address: address, branches: nodes, max_concurrency: cap}}
    end
  end

  # Each branch must be a single `agent` turn (the concurrency shape fans out agent
  # turns). Reuse `node/3` so a malformed branch raises the same located diagnostic
  # it would at top level; then require the result be an %Agent{}.
  defp agent_branches(branches, address, env) do
    branches
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {branch, i}, {:ok, acc} ->
      case node(branch, address ++ [i], env) do
        {:ok, %Agent{} = agent} ->
          {:cont, {:ok, [agent | acc]}}

        {:ok, _other} ->
          {:halt,
           {:error,
            Finding.at(env, branch, "`parallel` branches must be `agent` turns",
              hint: "each branch is one agent call, e.g. agent(\"...\")"
            )}}

        {:error, _} = err ->
          {:halt, err}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      err -> err
    end
  end

  defp pipeline(items_ast, stages_ast, opts, address, form, env) do
    with {:ok, items} <- pipeline_items(items_ast, form, env),
         {:ok, cap} <- concurrency_opt(opts, form, env),
         {:ok, stages} <- pipeline_stages(stages_ast, address, form, env) do
      # Expand each item into its own lane of pre-addressed agents:
      # lane `i`, stage `s` lives at `address ++ [i, s]`.
      lanes =
        items
        |> Enum.with_index()
        |> Enum.map(fn {_item, i} ->
          Enum.with_index(stages, fn %Agent{} = stage, s -> %{stage | address: address ++ [i, s]} end)
        end)

      {:ok, %Pipeline{address: address, items: items, lanes: lanes, max_concurrency: cap}}
    end
  end

  # `items` must be a non-empty literal list, materialized to plain data so lanes
  # (and their journalled item values) stay inert.
  defp pipeline_items(items_ast, form, env) do
    if is_list(items_ast) and Macro.quoted_literal?(items_ast) do
      case materialize(items_ast) do
        [] ->
          {:error, Finding.at(env, form, "`pipeline` requires at least one item")}

        items ->
          {:ok, items}
      end
    else
      {:error,
       Finding.at(env, form, "`pipeline` items must be a literal list",
         hint: ~s|pass a compile-time list, e.g. pipeline ["a", "b"], [agent("...")]|
       )}
    end
  end

  # Stage templates are agent turns; their address is overwritten per lane, so parse
  # them at a placeholder address and keep only prompt/schema/retries.
  defp pipeline_stages([], _address, form, env),
    do: {:error, Finding.at(env, form, "`pipeline` requires at least one stage")}

  defp pipeline_stages(stages, address, _form, env) when is_list(stages) do
    stages
    |> Enum.reduce_while({:ok, []}, fn stage, {:ok, acc} ->
      case node(stage, address, env) do
        {:ok, %Agent{} = agent} ->
          {:cont, {:ok, [agent | acc]}}

        {:ok, _other} ->
          {:halt,
           {:error,
            Finding.at(env, stage, "`pipeline` stages must be `agent` turns",
              hint: "each stage is one agent call, e.g. agent(\"...\")"
            )}}

        {:error, _} = err ->
          {:halt, err}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      err -> err
    end
  end

  defp pipeline_stages(_stages, _address, form, env),
    do: {:error, Finding.at(env, form, "`pipeline` stages must be a literal list of agents")}

  # The only fan-out option, shared by both combinators.
  defp concurrency_opt([], _form, _env), do: {:ok, nil}

  defp concurrency_opt(opts, form, env) do
    if keyword_literal?(opts) and Keyword.keyword?(opts) and Keyword.keys(opts) == [:max_concurrency] do
      case Keyword.fetch!(opts, :max_concurrency) do
        n when is_integer(n) and n > 0 -> {:ok, n}
        _ -> {:error, Finding.at(env, form, "`max_concurrency` must be a positive integer")}
      end
    else
      {:error,
       Finding.at(env, form, "invalid fan-out options",
         hint: "the only option is `max_concurrency: <pos integer>`"
       )}
    end
  end

  # Materialize a **verified-literal** AST into its runtime value. Total over the
  # literal subset `Macro.quoted_literal?/1` admits; used only after that gate, so
  # the compiled node carries plain data (a map), never a fragment of AST.
  defp materialize({:%{}, _, pairs}),
    do: Map.new(pairs, fn {k, v} -> {materialize(k), materialize(v)} end)

  defp materialize({:{}, _, elems}), do: elems |> Enum.map(&materialize/1) |> List.to_tuple()
  defp materialize({left, right}), do: {materialize(left), materialize(right)}
  defp materialize(list) when is_list(list), do: Enum.map(list, &materialize/1)
  defp materialize(literal), do: literal

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
