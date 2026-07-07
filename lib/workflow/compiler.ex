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

  alias Workflow.{Tree, Predicate, RenderText, Template}

  alias Workflow.Node.{
    Phase,
    Log,
    Agent,
    Emit,
    Return,
    Parallel,
    Pipeline,
    Collect,
    WhileBudget,
    UntilDry,
    Verify,
    Judge,
    Synthesize,
    FanOut,
    BudgetSlices
  }

  alias Workflow.Compiler.Finding

  # The closed combinator vocabulary. Determinism is a property of this set: it
  # contains no randomness or wall-clock node, so neither can be expressed.
  @combinators [
    :agent,
    :log,
    :phase,
    :parallel,
    :pipeline,
    :return,
    :emit,
    :collect,
    :while_budget,
    :until_dry,
    :verify,
    :judge,
    :synthesize,
    :fan_out
  ]

  # A voter/scorer casts a fail-closed, machine-checkable verdict/score, so its
  # output is schema-bound. Retries are disabled: a malformed vote/score is a hard
  # failure of the panel rather than a re-roll that could hide non-determinism.
  @verdict_schema %{
    "type" => "object",
    "properties" => %{"verdict" => %{"type" => "boolean"}},
    "required" => ["verdict"]
  }

  @score_schema %{
    "type" => "object",
    "properties" => %{"score" => %{"type" => "number"}},
    "required" => ["score"]
  }

  @pick_strategies [:max_score, :min_score]

  # Combinators a loop body may contain. Loops, fan-out, and `return` are rejected
  # inside a body, so the per-iteration key stays a single integer and each loop
  # provably terminates on its own budget/dryness bound.
  @body_combinators [:agent, :log, :phase, :collect]

  # Options a schema-backed `agent` accepts, and the default retry budget when
  # `retries:` is omitted (total attempts = retries + 1).
  @agent_option_keys [:schema, :retries]
  @default_retries 2

  # A structural safety bound so every loop terminates even if its budget/dryness
  # condition never fires. Authors may lower it with `max_iterations:`.
  @default_max_iterations 1000

  @spec parse(Macro.t(), Macro.Env.t()) :: {:ok, Tree.t()} | {:error, Finding.t()}
  def parse(block, env) do
    with {:ok, nodes} <- build(statements(block), 0, [], MapSet.new(), env, %{}),
         :ok <- validate_tree(nodes, env) do
      {:ok, %Tree{nodes: nodes}}
    end
  end

  # A single-statement body is not wrapped in a __block__.
  defp statements({:__block__, _meta, stmts}), do: stmts
  defp statements(nil), do: []
  defp statements(single), do: [single]

  # --- Per-statement build (per-node option errors located at the call site) ---

  defp build([], _index, acc, _seen, _env, _binding_env), do: {:ok, Enum.reverse(acc)}

  defp build([stmt | rest], index, acc, seen, env, binding_env) do
    case let_node(stmt, [index], env, binding_env) do
      {:ok, node, next_binding_env} ->
        finish_build(node, stmt, rest, index, acc, seen, env, next_binding_env)

      :no_match ->
        case node(stmt, [index], env, binding_env) do
          {:ok, node} ->
            finish_build(node, stmt, rest, index, acc, seen, env, binding_env)

          {:error, finding} ->
            {:error, finding}
        end

      {:error, finding} ->
        {:error, finding}
    end
  end

  defp finish_build(%Phase{name: name} = phase, stmt, rest, index, acc, seen, env, binding_env) do
    if MapSet.member?(seen, name) do
      {:error,
       Finding.at(env, stmt, "duplicate phase name #{inspect(name)}",
         hint: "phase names must be unique within a workflow"
       )}
    else
      build(rest, index + 1, [phase | acc], MapSet.put(seen, name), env, binding_env)
    end
  end

  defp finish_build(%node{} = built, stmt, rest, index, acc, seen, env, binding_env)
       when node in [Return, Emit] do
    if rest == [] do
      build(rest, index + 1, [built | acc], seen, env, binding_env)
    else
      {:error,
       Finding.at(env, stmt, "`#{terminal_name(built)}` must be the final top-level node",
         hint: "a workflow terminates with `return` or `emit`"
       )}
    end
  end

  defp finish_build(node, _stmt, rest, index, acc, seen, env, binding_env) do
    build(rest, index + 1, [node | acc], seen, env, binding_env)
  end

  defp let_node(
         {:let, _meta, [{:=, _eq_meta, [name, producer]}]} = form,
         address,
         env,
         binding_env
       ) do
    with :ok <- binding_name(name, form, env),
         {:ok, node} <- node(producer, address, env, binding_env),
         :ok <- bindable_producer(node, form, env) do
      {:ok, node, Map.put(binding_env, name, {:node, address})}
    end
  end

  defp let_node({:let, _meta, _args} = form, _address, env, _binding_env) do
    {:error,
     Finding.at(
       env,
       form,
       "`let` requires `let :name = agent(...)` or `let :name = synthesize(...)`"
     )}
  end

  defp let_node(_stmt, _address, _env, _binding_env), do: :no_match

  defp binding_name(name, form, env) when is_atom(name) do
    if String.match?(Atom.to_string(name), ~r/^[a-z_][a-zA-Z0-9_]*$/) do
      :ok
    else
      {:error,
       Finding.at(env, form, "inadmissible binding name #{inspect(name)}",
         hint: "binding names must look like `:draft` or `:summary`"
       )}
    end
  end

  defp binding_name(_name, form, env) do
    {:error, Finding.at(env, form, "`let` binding name must be an atom literal")}
  end

  defp bindable_producer(%Agent{}, _form, _env), do: :ok
  defp bindable_producer(%Synthesize{}, _form, _env), do: :ok

  defp bindable_producer(_other, form, env) do
    {:error,
     Finding.at(env, form, "`let` only binds `agent(...)` or `synthesize(...)` producers")}
  end

  defp terminal_name(%Return{}), do: "return"
  defp terminal_name(%Emit{}), do: "emit"

  # --- The closed combinator vocabulary ---

  defp node({:phase, _meta, [name]}, address, _env, _binding_env) when is_binary(name),
    do: {:ok, %Phase{address: address, name: name}}

  defp node({:log, _meta, [message]}, address, _env, _binding_env) when is_binary(message),
    do: {:ok, %Log{address: address, message: message}}

  defp node({:agent, _meta, [prompt]} = form, address, env, _binding_env)
       when is_binary(prompt) do
    with {:ok, prompt} <- prompt_text(prompt, form, env, "agent prompt") do
      {:ok, %Agent{address: address, prompt: prompt, schema: nil, retries: @default_retries}}
    end
  end

  defp node(
         {:agent, _meta, [{:sigil_P, _template_meta, _template_args} = template_ast]} = form,
         address,
         env,
         binding_env
       ) do
    with {:ok, template} <- prompt_template(template_ast, env),
         {:ok, bindings} <- emit_bindings(template, binding_env, form, env) do
      {:ok,
       %Agent{
         address: address,
         prompt: template,
         bindings: bindings,
         schema: nil,
         retries: @default_retries
       }}
    end
  end

  defp node({:agent, _meta, [{:<<>>, _, _parts}]} = form, _address, env, _binding_env),
    do: {:error, interpolation_finding(form, env, "agent prompt")}

  # A schema-backed agent: `agent "…", schema: %{…}, retries: n`. The options must
  # be a literal keyword list drawn from @agent_option_keys; the schema must be a
  # literal map (materialized to its runtime value so the node stays inert data).
  defp node({:agent, _meta, [prompt, opts]} = form, address, env, _binding_env)
       when is_binary(prompt) do
    with {:ok, prompt} <- prompt_text(prompt, form, env, "agent prompt"),
         {:ok, kw} <- agent_options(opts, form, env),
         {:ok, schema} <- agent_schema(kw, form, env),
         {:ok, retries} <- agent_retries(kw, form, env) do
      {:ok, %Agent{address: address, prompt: prompt, schema: schema, retries: retries}}
    end
  end

  defp node(
         {:agent, _meta, [{:sigil_P, _template_meta, _template_args} = template_ast, opts]} = form,
         address,
         env,
         binding_env
       ) do
    with {:ok, template} <- prompt_template(template_ast, env),
         {:ok, bindings} <- emit_bindings(template, binding_env, form, env),
         {:ok, kw} <- agent_options(opts, form, env),
         {:ok, schema} <- agent_schema(kw, form, env),
         {:ok, retries} <- agent_retries(kw, form, env) do
      {:ok,
       %Agent{
         address: address,
         prompt: template,
         bindings: bindings,
         schema: schema,
         retries: retries
       }}
    end
  end

  defp node({:agent, _meta, [{:<<>>, _, _parts}, _opts]} = form, _address, env, _binding_env),
    do: {:error, interpolation_finding(form, env, "agent prompt")}

  defp node({:return, _meta, [value]} = form, address, env, _binding_env) do
    if Macro.quoted_literal?(value) do
      {:ok, %Return{address: address, value: value}}
    else
      {:error,
       Finding.at(env, form, "`return` expects a literal value",
         hint: "return only compile-time constants; a workflow cannot compute at runtime"
       )}
    end
  end

  defp node({:emit, _meta, [template_ast]} = form, address, env, binding_env) do
    with {:ok, template} <- emit_template(template_ast, env),
         {:ok, bindings} <- emit_bindings(template, binding_env, form, env) do
      {:ok, %Emit{address: address, template: template, bindings: bindings}}
    end
  end

  # `parallel [agent(...), ...]` — a barrier fan-out over a literal list of agent
  # branches, optionally capped by `max_concurrency:`. Each branch is addressed
  # `address ++ [branch_index]`, so branches journal and key independently.
  defp node({:parallel, _meta, [branches]} = form, address, env, binding_env)
       when is_list(branches),
       do: parallel(branches, [], address, form, env, binding_env)

  defp node({:parallel, _meta, [branches, opts]} = form, address, env, binding_env)
       when is_list(branches),
       do: parallel(branches, opts, address, form, env, binding_env)

  # `pipeline items, [agent(...), ...]` — per-item lanes through ordered stages,
  # optionally capped by `max_concurrency:`. `items` is a literal list; the lanes
  # are expanded here into pre-addressed inert agents.
  defp node({:pipeline, _meta, [items, stages]} = form, address, env, binding_env),
    do: pipeline(items, stages, [], address, form, env, binding_env)

  defp node({:pipeline, _meta, [items, stages, opts]} = form, address, env, binding_env),
    do: pipeline(items, stages, opts, address, form, env, binding_env)

  # `while_budget reserve: N[, until: <predicate>][, max_iterations: N] do <body> end`
  # — a dynamic loop whose body runs while the ledger's `remaining` exceeds `reserve`.
  defp node({:while_budget, _meta, args} = form, address, env, binding_env) do
    with {:ok, opts, block} <- loop_call(args, form, env),
         :ok <- only_keys(opts, [:reserve, :until, :max_iterations], form, env),
         {:ok, reserve} <- required_integer(opts, :reserve, 0, form, env),
         {:ok, until_pred} <- optional_predicate(opts, env),
         {:ok, cap} <- max_iterations(opts, form, env),
         {:ok, body} <- parse_body(block, address, form, env, binding_env) do
      {:ok,
       %WhileBudget{
         address: address,
         reserve: reserve,
         until: until_pred,
         body: body,
         max_iterations: cap
       }}
    end
  end

  # `until_dry rounds: K, seen_by: [:field, ...][, max_iterations: N] do <body> end`
  # — loops until K consecutive iterations add nothing new (deduped by `seen_by`).
  defp node({:until_dry, _meta, args} = form, address, env, binding_env) do
    with {:ok, opts, block} <- loop_call(args, form, env),
         :ok <- only_keys(opts, [:rounds, :seen_by, :max_iterations], form, env),
         {:ok, rounds} <- required_integer(opts, :rounds, 1, form, env),
         {:ok, seen_by} <- seen_by_opt(opts, form, env),
         {:ok, cap} <- max_iterations(opts, form, env),
         {:ok, body} <- parse_body(block, address, form, env, binding_env),
         :ok <- require_collect(body, form, env) do
      {:ok,
       %UntilDry{
         address: address,
         rounds: rounds,
         seen_by: seen_by,
         body: body,
         max_iterations: cap
       }}
    end
  end

  # `verify subject, voters: N, threshold: :majority` /
  # `verify subject, lenses: [:a, :b], threshold: :unanimous` — submit a literal
  # finding to a bounded panel of votes and survive only when `threshold` confirm.
  # The panel is fixed at author time (a compile-time constant width), so the voters
  # are pre-expanded into inert, pre-addressed, schema-bound agents.
  defp node({:verify, _meta, [subject, opts]} = form, address, env, _binding_env) do
    with {:ok, lit} <- verify_subject(subject, form, env),
         :ok <- only_keys(opts, [:voters, :lenses, :threshold], form, env),
         {:ok, mode} <- verify_mode(opts, form, env),
         {:ok, threshold} <- verify_threshold(opts, mode, form, env) do
      {:ok,
       %Verify{
         address: address,
         subject: lit,
         mode: mode,
         voters: verify_voters(mode, lit, address),
         threshold: threshold
       }}
    end
  end

  # `judge candidates, by: [:c1, :c2], pick: :max_score` — score each literal
  # candidate along each criterion and pick a winner. The scoring grid (candidates ×
  # criteria, both compile-time constants) is pre-expanded into inert, pre-addressed,
  # schema-bound scorer agents.
  defp node({:judge, _meta, [candidates, opts]} = form, address, env, _binding_env) do
    with {:ok, list} <- judge_candidates(candidates, form, env),
         :ok <- only_keys(opts, [:by, :pick], form, env),
         {:ok, by} <- judge_by(opts, form, env),
         {:ok, pick} <- judge_pick(opts, form, env) do
      {:ok,
       %Judge{
         address: address,
         candidates: list,
         by: by,
         pick: pick,
         scorers: judge_scorers(list, by, address)
       }}
    end
  end

  # `synthesize inputs, "prompt"` — fold literal inputs into one result under a
  # static prompt. Both are compile-time literals, so the node stays inert.
  defp node({:synthesize, _meta, [inputs, prompt]} = form, address, env, _binding_env)
       when is_binary(prompt) do
    with {:ok, prompt} <- prompt_text(prompt, form, env, "synthesize prompt") do
      if Macro.quoted_literal?(inputs) do
        {:ok, %Synthesize{address: address, inputs: materialize(inputs), prompt: prompt}}
      else
        {:error,
         Finding.at(env, form, "`synthesize` inputs must be a literal",
           hint: "pass compile-time constants; a workflow cannot compute inputs at runtime"
         )}
      end
    end
  end

  defp node(
         {:synthesize, _meta, [inputs, {:<<>>, _, _parts}]} = form,
         _address,
         env,
         _binding_env
       ) do
    if Macro.quoted_literal?(inputs) do
      {:error, interpolation_finding(form, env, "synthesize prompt")}
    else
      {:error,
       Finding.at(env, form, "`synthesize` prompt must be a literal string",
         hint: ~s|synthesize inputs, "a static instruction"|
       )}
    end
  end

  defp node({:synthesize, _meta, [_inputs, _prompt]} = form, _address, env, _binding_env) do
    {:error,
     Finding.at(env, form, "`synthesize` prompt must be a literal string",
       hint: ~s|synthesize inputs, "a static instruction"|
     )}
  end

  # `fan_out width: budget_slices(per: N)[, max_concurrency: M] do <body> end` —
  # run the body across `floor(remaining / N)` concurrent branches. The width is a
  # runtime-owned budget decision, never author arithmetic, so `width:` accepts only
  # a `budget_slices(per:)` form.
  defp node({:fan_out, _meta, args} = form, address, env, binding_env) do
    with {:ok, opts, block} <- loop_call(args, form, env),
         :ok <- only_keys(opts, [:width, :max_concurrency], form, env),
         {:ok, width} <- fan_out_width(opts, form, env),
         {:ok, cap} <- fan_out_concurrency(opts, form, env),
         {:ok, body} <- fan_out_body(block, address, form, env, binding_env) do
      {:ok, %FanOut{address: address, width: width, body: body, max_concurrency: cap}}
    end
  end

  # `collect` is only meaningful inside a loop body; at top level it is rejected. The
  # body parser handles the in-loop form before delegating here.
  defp node({:collect, _meta, _args} = form, _address, env, _binding_env) do
    {:error,
     Finding.at(env, form, "`collect` must appear inside a loop body",
       hint: "collect reduces a loop iteration's agent output into a declared accumulator"
     )}
  end

  # A known combinator invoked with the wrong argument shape: recoverable finding,
  # located at the declaration site.
  defp node({combinator, _meta, _args} = form, _address, env, _binding_env)
       when combinator in @combinators,
       do: {:error, Finding.at(env, form, "`#{combinator}` was called with invalid arguments")}

  # --- Forbidden-form catalog: everything below raises, so non-determinism and
  # escape hatches are unrepresentable in a compiled tree. ---

  # Anonymous functions destroy total-validation, serialization, and resume.
  defp node({:fn, _meta, _clauses} = form, _address, env, _binding_env) do
    raise_finding(
      Finding.at(env, form, "anonymous functions are not part of the workflow vocabulary",
        hint: "a workflow is inert, serializable data — it cannot capture a closure"
      )
    )
  end

  # Any call into an external module — `:rand.*`, `System.*`, `Enum.*`, ... .
  defp node({{:., _, [_module, _fun]}, _meta, _args} = form, _address, env, _binding_env) do
    raise_finding(
      Finding.at(env, form, "calls to external modules are not part of the workflow vocabulary",
        hint: "a workflow must be deterministic and self-contained (no #{callee(form)})"
      )
    )
  end

  # An unknown bare call: reject with a closed-vocabulary suggestion.
  defp node({name, _meta, args} = form, _address, env, _binding_env)
       when is_atom(name) and is_list(args) do
    raise_finding(Finding.at(env, form, "unknown combinator `#{name}`", hint: suggest(name)))
  end

  # Anything else — a stray literal, a variable, an operator: outside the vocabulary.
  defp node(form, _address, env, _binding_env) do
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

      # A schema module built by `Workflow.Schema.DSL`: resolve the alias and lift
      # its inert JSON-schema map into the node, so `schema: Bugs` is identical to
      # passing that map literally — the node still carries plain, serializable data.
      {:ok, {:__aliases__, _, _} = alias_ast} ->
        schema_from_module(Macro.expand(alias_ast, env), form, env)

      {:ok, _not_a_map_literal} ->
        {:error, schema_finding(form, env)}

      :error ->
        {:error,
         Finding.at(env, form, "`agent` with options requires a `schema:`",
           hint: "schema-backed agents fail closed; give schema: %{...} or a schema module"
         )}
    end
  end

  # Reflect the compiled schema map out of a `schema … do … end` module. The remote
  # call establishes a compile-time dependency, so the schema module is compiled
  # before this workflow; a module that is not a schema is a located finding.
  defp schema_from_module(module, form, env) when is_atom(module) do
    case Code.ensure_compiled(module) do
      {:module, ^module} ->
        if function_exported?(module, :__schema__, 1) do
          {:ok, module.__schema__(:json)}
        else
          {:error,
           Finding.at(env, form, "`schema:` module #{inspect(module)} is not a schema",
             hint: "define it with `schema #{inspect(module)} do ... end`"
           )}
        end

      {:error, _reason} ->
        {:error,
         Finding.at(env, form, "`schema:` references an unknown module #{inspect(module)}")}
    end
  end

  defp schema_finding(form, env) do
    Finding.at(env, form, "`agent` schema must be a literal map",
      hint: ~s|pass a raw JSON-schema map literal, e.g. schema: %{"type" => "object"}|
    )
  end

  defp agent_retries(kw, form, env) do
    case Keyword.fetch(kw, :retries) do
      :error ->
        {:ok, @default_retries}

      {:ok, n} when is_integer(n) and n >= 0 ->
        {:ok, n}

      {:ok, _} ->
        {:error, Finding.at(env, form, "`agent` retries must be a non-negative integer")}
    end
  end

  # --- Static fan-out combinators (parallel / pipeline) ---

  defp parallel([], _opts, _address, form, env, _binding_env) do
    {:error,
     Finding.at(env, form, "`parallel` requires at least one branch",
       hint: "parallel [agent(\"...\"), agent(\"...\")]"
     )}
  end

  defp parallel(branches, opts, address, form, env, binding_env) do
    with {:ok, cap} <- concurrency_opt(opts, form, env),
         {:ok, nodes} <- agent_branches(branches, address, env, binding_env) do
      {:ok, %Parallel{address: address, branches: nodes, max_concurrency: cap}}
    end
  end

  # Each branch must be a single `agent` turn (the concurrency shape fans out agent
  # turns). Reuse `node/3` so a malformed branch raises the same located diagnostic
  # it would at top level; then require the result be an %Agent{}.
  defp agent_branches(branches, address, env, binding_env) do
    branches
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {branch, i}, {:ok, acc} ->
      case node(branch, address ++ [i], env, binding_env) do
        {:ok, %Agent{prompt: %Template{}}} ->
          {:halt, {:error, nested_template_prompt_finding(env, branch, "parallel branches")}}

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

  defp pipeline(items_ast, stages_ast, opts, address, form, env, binding_env) do
    with {:ok, items} <- pipeline_items(items_ast, form, env),
         {:ok, cap} <- concurrency_opt(opts, form, env),
         {:ok, stages} <- pipeline_stages(stages_ast, address, form, env, binding_env) do
      # Expand each item into its own lane of pre-addressed agents:
      # lane `i`, stage `s` lives at `address ++ [i, s]`.
      lanes =
        items
        |> Enum.with_index()
        |> Enum.map(fn {_item, i} ->
          Enum.with_index(stages, fn %Agent{} = stage, s ->
            %{stage | address: address ++ [i, s]}
          end)
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
  defp pipeline_stages([], _address, form, env, _binding_env),
    do: {:error, Finding.at(env, form, "`pipeline` requires at least one stage")}

  defp pipeline_stages(stages, address, _form, env, binding_env) when is_list(stages) do
    stages
    |> Enum.reduce_while({:ok, []}, fn stage, {:ok, acc} ->
      case node(stage, address, env, binding_env) do
        {:ok, %Agent{prompt: %Template{}}} ->
          {:halt, {:error, nested_template_prompt_finding(env, stage, "pipeline stages")}}

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

  defp pipeline_stages(_stages, _address, form, env, _binding_env),
    do: {:error, Finding.at(env, form, "`pipeline` stages must be a literal list of agents")}

  # The only fan-out option, shared by both combinators.
  defp concurrency_opt([], _form, _env), do: {:ok, nil}

  defp concurrency_opt(opts, form, env) do
    if keyword_literal?(opts) and Keyword.keyword?(opts) and
         Keyword.keys(opts) == [:max_concurrency] do
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

  # --- Dynamic loop combinators (while_budget / until_dry / collect) ---

  # Split a loop call's args into its option keyword list and its do-block body.
  # Elixir parses `foo opt: v do ... end` as `[[opt: v], [do: block]]`.
  defp loop_call([opts, [do: block]], _form, _env) when is_list(opts), do: {:ok, opts, block}
  defp loop_call([[do: block]], _form, _env), do: {:ok, [], block}

  defp loop_call(_args, form, env) do
    {:error,
     Finding.at(env, form, "a loop requires options and a `do` block",
       hint: "e.g. while_budget reserve: 100 do agent(\"...\") end"
     )}
  end

  # The loop body is a fresh sub-tree; its nodes are addressed `parent ++ [i]` so
  # they journal and key independently while every iteration re-runs the same
  # addresses under a distinct `iteration`.
  defp parse_body(block, loop_address, form, env, binding_env) do
    case build_body(statements(block), loop_address, 0, [], MapSet.new(), env, binding_env) do
      {:ok, []} -> {:error, Finding.at(env, form, "a loop body must contain at least one node")}
      other -> other
    end
  end

  defp build_body([], _loop_address, _index, acc, _seen, _env, _binding_env),
    do: {:ok, Enum.reverse(acc)}

  defp build_body([stmt | rest], loop_address, index, acc, seen, env, binding_env) do
    case body_node(stmt, loop_address ++ [index], env, binding_env) do
      {:ok, %Phase{name: name} = phase} ->
        if MapSet.member?(seen, name) do
          {:error, Finding.at(env, stmt, "duplicate phase name #{inspect(name)}")}
        else
          build_body(
            rest,
            loop_address,
            index + 1,
            [phase | acc],
            MapSet.put(seen, name),
            env,
            binding_env
          )
        end

      {:ok, node} ->
        build_body(rest, loop_address, index + 1, [node | acc], seen, env, binding_env)

      {:error, _} = err ->
        err
    end
  end

  # A loop body permits the body vocabulary plus `collect`; loops, fan-out, and
  # `return` are rejected here (keeping the iteration key a single integer), while
  # closures/external calls still raise via the shared forbidden-form catalog.
  defp body_node({:collect, _meta, [opts]} = form, address, env, _binding_env),
    do: collect(opts, form, address, env)

  defp body_node({:collect, _meta, _args} = form, _address, env, _binding_env),
    do: {:error, Finding.at(env, form, "`collect` requires `into: :name`")}

  defp body_node({:let, _meta, _args} = form, _address, env, _binding_env),
    do: {:error, Finding.at(env, form, "`let` is not allowed inside a loop body")}

  defp body_node({:emit, _meta, _args} = form, _address, env, _binding_env),
    do: {:error, Finding.at(env, form, "`emit` is not allowed inside a loop body")}

  defp body_node({combinator, _meta, _args} = form, _address, env, _binding_env)
       when combinator in [
              :while_budget,
              :until_dry,
              :parallel,
              :pipeline,
              :return,
              :verify,
              :judge,
              :synthesize,
              :fan_out
            ] do
    {:error,
     Finding.at(env, form, "`#{combinator}` is not allowed inside a loop body",
       hint: "a loop body may contain: #{Enum.join(@body_combinators, ", ")}"
     )}
  end

  defp body_node(stmt, address, env, binding_env) do
    case node(stmt, address, env, binding_env) do
      {:ok, %Agent{prompt: %Template{}}} ->
        {:error, nested_template_prompt_finding(env, stmt, "loop body")}

      other ->
        other
    end
  end

  defp collect(opts, form, address, env) do
    cond do
      not (keyword_literal?(opts) and Keyword.keyword?(opts)) ->
        {:error, Finding.at(env, form, "`collect` requires `into: :name`")}

      Keyword.keys(opts) != [:into] ->
        {:error, Finding.at(env, form, "`collect` takes exactly one option, `into: :name`")}

      not is_atom(Keyword.fetch!(opts, :into)) ->
        {:error, Finding.at(env, form, "`collect` `into:` must be an accumulator name (an atom)")}

      true ->
        {:ok, %Collect{address: address, into: Keyword.fetch!(opts, :into)}}
    end
  end

  defp require_collect(body, form, env) do
    if Enum.any?(body, &match?(%Collect{}, &1)) do
      :ok
    else
      {:error,
       Finding.at(env, form, "`until_dry` body must `collect` into an accumulator",
         hint: "dryness is measured over what the body accumulates; add collect into: :name"
       )}
    end
  end

  defp only_keys(opts, allowed, form, env) do
    if keyword_literal?(opts) and Keyword.keyword?(opts) and
         Enum.all?(Keyword.keys(opts), &(&1 in allowed)) do
      :ok
    else
      {:error,
       Finding.at(env, form, "invalid loop options",
         hint: "allowed options: #{Enum.join(allowed, ", ")}"
       )}
    end
  end

  defp required_integer(opts, key, min, form, env) do
    case Keyword.fetch(opts, key) do
      {:ok, n} when is_integer(n) and n >= min ->
        {:ok, n}

      {:ok, _} ->
        {:error, Finding.at(env, form, "`#{key}` must be an integer >= #{min}")}

      :error ->
        {:error, Finding.at(env, form, "a loop requires `#{key}:`")}
    end
  end

  defp optional_predicate(opts, env) do
    case Keyword.fetch(opts, :until) do
      :error -> {:ok, nil}
      {:ok, ast} -> Predicate.parse(ast, env)
    end
  end

  defp max_iterations(opts, form, env) do
    case Keyword.fetch(opts, :max_iterations) do
      :error -> {:ok, @default_max_iterations}
      {:ok, n} when is_integer(n) and n > 0 -> {:ok, n}
      {:ok, _} -> {:error, Finding.at(env, form, "`max_iterations` must be a positive integer")}
    end
  end

  defp seen_by_opt(opts, form, env) do
    case Keyword.fetch(opts, :seen_by) do
      :error ->
        {:ok, []}

      {:ok, fields} when is_list(fields) ->
        if Enum.all?(fields, &is_atom/1) do
          {:ok, fields}
        else
          {:error, Finding.at(env, form, "`seen_by` must be a list of field names (atoms)")}
        end

      {:ok, _} ->
        {:error,
         Finding.at(env, form, "`seen_by` must be a field list, never a function",
           hint: "e.g. seen_by: [:file, :line] — a list so validation can see it"
         )}
    end
  end

  # --- Quality combinators: verify / judge / synthesize / fan_out ---

  defp verify_subject(subject, form, env) do
    if Macro.quoted_literal?(subject) do
      {:ok, materialize(subject)}
    else
      {:error,
       Finding.at(env, form, "`verify` subject must be a literal",
         hint: "pass a compile-time finding, e.g. verify \"the bug reproduces\", voters: 3"
       )}
    end
  end

  # Exactly one of `voters:` / `lenses:` selects the panel; both or neither is an
  # error. Counts are fixed at author time, so the fan-out width is a constant.
  defp verify_mode(opts, form, env) do
    case {Keyword.fetch(opts, :voters), Keyword.fetch(opts, :lenses)} do
      {{:ok, n}, :error} when is_integer(n) and n > 0 ->
        {:ok, {:voters, n}}

      {{:ok, _bad}, :error} ->
        {:error, Finding.at(env, form, "`verify` `voters:` must be a positive integer")}

      {:error, {:ok, lenses}} when is_list(lenses) and lenses != [] ->
        if Enum.all?(lenses, &is_atom/1) do
          {:ok, {:lenses, lenses}}
        else
          {:error,
           Finding.at(env, form, "`verify` `lenses:` must be a list of perspective atoms")}
        end

      {:error, {:ok, _bad}} ->
        {:error,
         Finding.at(env, form, "`verify` `lenses:` must be a non-empty list of perspective atoms")}

      {{:ok, _}, {:ok, _}} ->
        {:error,
         Finding.at(env, form, "`verify` takes either `voters:` or `lenses:`, not both",
           hint: "choose redundant voters or perspective-diverse lenses"
         )}

      {:error, :error} ->
        {:error,
         Finding.at(env, form, "`verify` requires `voters: N` or `lenses: [...]`",
           hint: "e.g. verify \"finding\", voters: 3, threshold: :majority"
         )}
    end
  end

  # `threshold:` defaults to `:majority`; an integer count must not exceed the panel.
  defp verify_threshold(opts, mode, form, env) do
    total = voter_count(mode)

    case Keyword.fetch(opts, :threshold) do
      :error -> {:ok, :majority}
      {:ok, t} when t in [:majority, :unanimous, :any] -> {:ok, t}
      {:ok, n} when is_integer(n) and n > 0 and n <= total -> {:ok, n}
      {:ok, n} when is_integer(n) -> {:error, threshold_finding(form, env, total)}
      {:ok, _} -> {:error, threshold_finding(form, env, total)}
    end
  end

  defp threshold_finding(form, env, total) do
    Finding.at(env, form, "`verify` threshold is out of range",
      hint: "threshold: :majority | :unanimous | :any | 1..#{total}"
    )
  end

  defp voter_count({:voters, n}), do: n
  defp voter_count({:lenses, lenses}), do: length(lenses)

  # Pre-expand the panel into inert, pre-addressed, schema-bound votes. Voter mode
  # casts N identical votes; lens mode casts one perspective-framed vote per lens.
  defp verify_voters({:voters, n}, subject, address) do
    Enum.map(0..(n - 1), fn i ->
      %Agent{
        address: address ++ [i],
        prompt: verify_prompt(subject, nil),
        schema: @verdict_schema,
        retries: 0
      }
    end)
  end

  defp verify_voters({:lenses, lenses}, subject, address) do
    Enum.with_index(lenses, fn lens, i ->
      %Agent{
        address: address ++ [i],
        prompt: verify_prompt(subject, lens),
        schema: @verdict_schema,
        retries: 0
      }
    end)
  end

  defp verify_prompt(subject, nil),
    do:
      RenderText.render!([], [
        {:text, "Confirm or refute this finding, answering with a boolean verdict: "},
        {:literal, subject}
      ])

  defp verify_prompt(subject, lens),
    do:
      RenderText.render!([], [
        {:text, "From the #{lens} perspective, confirm or refute this finding, "},
        {:text, "answering with a boolean verdict: "},
        {:literal, subject}
      ])

  defp judge_candidates(candidates, form, env) do
    if is_list(candidates) and Macro.quoted_literal?(candidates) do
      case materialize(candidates) do
        [] -> {:error, Finding.at(env, form, "`judge` requires at least one candidate")}
        list -> {:ok, list}
      end
    else
      {:error,
       Finding.at(env, form, "`judge` candidates must be a literal list",
         hint:
           ~s|pass a compile-time list, e.g. judge ["a", "b"], by: [:quality], pick: :max_score|
       )}
    end
  end

  defp judge_by(opts, form, env) do
    case Keyword.fetch(opts, :by) do
      {:ok, by} when is_list(by) and by != [] ->
        if Enum.all?(by, &is_atom/1),
          do: {:ok, by},
          else: {:error, Finding.at(env, form, "`judge` `by:` must be a list of criterion atoms")}

      {:ok, _} ->
        {:error,
         Finding.at(env, form, "`judge` `by:` must be a non-empty list of criterion atoms")}

      :error ->
        {:error,
         Finding.at(env, form, "`judge` requires `by: [:criterion, ...]`",
           hint: "name the scoring criteria, e.g. by: [:feasibility, :impact]"
         )}
    end
  end

  defp judge_pick(opts, form, env) do
    case Keyword.fetch(opts, :pick) do
      {:ok, pick} when pick in @pick_strategies ->
        {:ok, pick}

      {:ok, _} ->
        {:error,
         Finding.at(env, form, "`judge` `pick:` is out of vocabulary",
           hint: "pick: #{Enum.join(@pick_strategies, " | ")}"
         )}

      :error ->
        {:error,
         Finding.at(env, form, "`judge` requires `pick: :max_score` or `pick: :min_score`")}
    end
  end

  # Expand the candidate × criterion grid into inert, pre-addressed scorer agents:
  # candidate `c`, criterion `k` lives at `address ++ [c, k]`.
  defp judge_scorers(candidates, by, address) do
    candidates
    |> Enum.with_index()
    |> Enum.map(fn {candidate, c} ->
      Enum.with_index(by, fn criterion, k ->
        %Agent{
          address: address ++ [c, k],
          prompt: score_prompt(candidate, criterion),
          schema: @score_schema,
          retries: 0
        }
      end)
    end)
  end

  defp score_prompt(candidate, criterion),
    do:
      RenderText.render!([], [
        {:text, "Score this candidate on #{criterion}, answering with a numeric score: "},
        {:literal, candidate}
      ])

  # `width:` accepts only `budget_slices(per: N)` — the runtime-owned width helper —
  # so authors cannot smuggle in arbitrary arithmetic.
  defp fan_out_width(opts, form, env) do
    case Keyword.fetch(opts, :width) do
      {:ok, {:budget_slices, _meta, [[per: n]]}} when is_integer(n) and n > 0 ->
        {:ok, %BudgetSlices{per: n}}

      {:ok, {:budget_slices, _meta, _args}} ->
        {:error, Finding.at(env, form, "`budget_slices` requires a positive `per:` integer")}

      {:ok, _} ->
        {:error,
         Finding.at(env, form, "`fan_out` width must be `budget_slices(per: N)`",
           hint: "width is a runtime budget decision, not author arithmetic"
         )}

      :error ->
        {:error, Finding.at(env, form, "`fan_out` requires `width: budget_slices(per: N)`")}
    end
  end

  defp fan_out_concurrency(opts, form, env) do
    case Keyword.fetch(opts, :max_concurrency) do
      :error -> {:ok, nil}
      {:ok, n} when is_integer(n) and n > 0 -> {:ok, n}
      {:ok, _} -> {:error, Finding.at(env, form, "`max_concurrency` must be a positive integer")}
    end
  end

  # The fan_out body is a lane of agent turns (like a pipeline stage list), parsed at
  # a placeholder address and re-addressed per branch at runtime.
  defp fan_out_body(block, address, form, env, binding_env) do
    case agent_lane(statements(block), address, env, binding_env) do
      {:ok, []} ->
        {:error,
         Finding.at(env, form, "`fan_out` requires at least one body step",
           hint:
             "the body is a lane of agent turns, e.g. fan_out width: ... do agent(\"...\") end"
         )}

      {:ok, agents} ->
        {:ok, agents}

      {:error, _} = err ->
        err
    end
  end

  # Parse a list of statements that must each be an `agent` turn (shared by fan_out).
  # Reuses `node/3`, so a closure/external call still raises via the forbidden-form
  # catalog and any malformed agent surfaces its own located finding.
  defp agent_lane(stmts, address, env, binding_env) do
    stmts
    |> Enum.reduce_while({:ok, []}, fn stmt, {:ok, acc} ->
      case node(stmt, address, env, binding_env) do
        {:ok, %Agent{prompt: %Template{}}} ->
          {:halt, {:error, nested_template_prompt_finding(env, stmt, "fan_out body")}}

        {:ok, %Agent{} = agent} ->
          {:cont, {:ok, [agent | acc]}}

        {:ok, _other} ->
          {:halt,
           {:error,
            Finding.at(env, stmt, "`fan_out` body steps must be `agent` turns",
              hint: "each step is one agent call, e.g. agent(\"...\")"
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

  # --- Whole-DSL invariants ---

  defp validate_tree(nodes, env) do
    case List.last(nodes) do
      %Return{} ->
        :ok

      %Emit{} ->
        :ok

      _other ->
        {:error,
         Finding.at(env, nil, "workflow must terminate with `return` or `emit`",
           hint: "end the workflow with `return literal` or `emit(~P\"...\")`"
         )}
    end
  end

  defp prompt_text(prompt, form, env, subject) when is_binary(prompt) do
    if String.contains?(prompt, "\#{") do
      {:error, interpolation_finding(form, env, subject)}
    else
      {:ok, prompt}
    end
  end

  defp interpolation_finding(form, env, subject) do
    Finding.at(env, form, "#{subject} interpolation is not allowed",
      hint: "bind producer results with `let`, then render them with `emit(~P\"...\")`"
    )
  end

  defp emit_template({:sigil_P, meta, [{:<<>>, _content_meta, [source]}, _mods]}, env)
       when is_binary(source) do
    Template.parse(source, %{env | line: Keyword.get(meta, :line, env.line)})
  end

  defp emit_template(_other, env) do
    {:error,
     Finding.at(env, nil, "`emit` expects a `~P` template",
       hint: ~s|emit(~P"Final: <%= @draft %>")|
     )}
  end

  defp prompt_template({:sigil_P, meta, [{:<<>>, _content_meta, [source]}, _mods]}, env)
       when is_binary(source) do
    Template.parse(source, %{env | line: Keyword.get(meta, :line, env.line)})
  end

  defp prompt_template(_other, env) do
    {:error,
     Finding.at(env, nil, "`agent` template prompts must use `~P`",
       hint: ~s|agent(~P"Improve this draft: <%= @draft %>")|
     )}
  end

  defp emit_bindings(%Template{assigns: assigns}, binding_env, form, env) do
    assigns
    |> Enum.uniq()
    |> Enum.reduce_while({:ok, %{}}, fn assign, {:ok, acc} ->
      case resolve_binding(assign, binding_env) do
        {:ok, name, ref} ->
          {:cont, {:ok, Map.put(acc, name, ref)}}

        :error ->
          {:halt,
           {:error,
            Finding.at(env, form, "unbound template assign @#{assign}",
              hint: "bind it earlier with `let :#{assign} = agent(...)` or `synthesize(...)`"
            )}}
      end
    end)
  end

  defp resolve_binding(assign, binding_env) do
    case Enum.find(binding_env, fn {name, _ref} -> Atom.to_string(name) == assign end) do
      {name, ref} -> {:ok, name, ref}
      nil -> :error
    end
  end

  defp nested_template_prompt_finding(env, form, context) do
    Finding.at(
      env,
      form,
      "template prompts are only allowed on top-level agents, not in #{context}",
      hint: "move this `~P` prompt out of #{context} and bind its inputs with `let` first"
    )
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
