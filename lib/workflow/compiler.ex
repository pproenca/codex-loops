defmodule Workflow.Compiler do
  @moduledoc """
  Turns a workflow name and quoted body into an inert `%Workflow.Tree{}`.

  This is the whole language implementation. It consumes AST as data, performs no
  expansion or evaluation, and returns either the compiled tree or one structured,
  caller-located finding.

  ## Failure modes

  Determinism is enforced by the **absence of vocabulary nodes plus compiler
  rejection**, never a runtime linter. There is no node for randomness or
  wall-clock, so a workflow cannot express them; the forbidden-form catalog below
  makes the escape hatches unrepresentable too. Every diagnostic is
  caller-located: it cites the user's `file:line` taken from the offending form's
  AST metadata.

    * **Outside the vocabulary** — a closure (`fn -> ... end`), a call to any
      external module (`:rand.*`, `System.*`, `Enum.*`, ...), an unknown bare call,
      or a stray literal/variable — returns `{:error, %Finding{}}`. Unknown
      combinators carry a closed-vocabulary suggestion ("did you mean ...").
    * **A known combinator with the wrong argument shape** (per-node option error)
      returns `{:error, %Finding{}}` located at the declaration site.
    * **Whole-DSL invariants** — duplicate phase names, a workflow with no
      `return` — return `{:error, %Finding{}}` located at the offending
      declaration (or the workflow itself, for a missing `return`).

  There is one failure channel for every expected authoring error: a tagged
  finding. `Workflow.Script` formats that finding at the path boundary.
  """

  alias Workflow.Compiler.Finding
  alias Workflow.Node.Agent
  alias Workflow.Node.BudgetSlices
  alias Workflow.Node.Collect
  alias Workflow.Node.Emit
  alias Workflow.Node.EmitResult
  alias Workflow.Node.GenericFanout
  alias Workflow.Node.Judge
  alias Workflow.Node.Log
  alias Workflow.Node.Loop
  alias Workflow.Node.Parallel
  alias Workflow.Node.PathCount
  alias Workflow.Node.Phase
  alias Workflow.Node.Pipeline
  alias Workflow.Node.Refine
  alias Workflow.Node.Return
  alias Workflow.Node.Synthesize
  alias Workflow.Node.Until
  alias Workflow.Node.Verify
  alias Workflow.Predicate
  alias Workflow.Refine.Gate
  alias Workflow.Refine.Reviewer
  alias Workflow.Refine.ReviewerAdapter
  alias Workflow.RenderText
  alias Workflow.Template
  alias Workflow.Tree

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
    :emit_result,
    :collect,
    :loop,
    :until,
    :while_budget,
    :until_dry,
    :verify,
    :refine,
    :judge,
    :synthesize,
    :fanout,
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

  @artifact_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "properties" => %{"artifact" => %{"type" => "string"}},
    "required" => ["artifact"]
  }

  @refine_required_options [:reviewers, :revise_with, :until, :max_rounds]
  @refine_optional_options [:on_non_convergence, :max_concurrency, :gates]
  @refine_allowed_options @refine_required_options ++ @refine_optional_options
  @refine_gate_options [:cold_read, :repair_when, :halt_when]
  @gate_compare_ops [:>, :<, :>=, :<=, :==]

  @pick_strategies [:max_score, :min_score]

  # Combinators a loop body may contain. The generic core admits body `until` and
  # generic fanout. Legacy loop sugar keeps the older compatibility subset.
  @generic_body_combinators [:agent, :log, :phase, :until, :fanout, :collect]
  @legacy_body_combinators [:agent, :log, :phase, :collect]

  # Options an `agent` accepts, and the default retry budget when `retries:` is
  # omitted (total attempts = retries + 1). `label:` is display metadata only; it
  # stays inert and never changes execution or idempotency.
  @agent_option_keys [:schema, :retries, :label]
  @default_retries 2
  @max_agent_retries 5

  # A structural safety bound so every loop terminates even if its budget/dryness
  # condition never fires. Authors may lower it with `max_iterations:`.
  @default_max_iterations 1000
  @max_loop_iterations 1000
  @max_fanout_width 64

  @spec compile(String.t(), Macro.t(), Macro.Env.t()) ::
          {:ok, Tree.t()} | {:error, Finding.t()}
  def compile(name, block, env) when is_binary(name) do
    with {:ok, nodes} <- build(statements(block), 0, [], %{}, env, %{}),
         :ok <- validate_tree(nodes, env) do
      {:ok, %Tree{name: name, nodes: nodes}}
    end
  end

  def compile(name, block, env) do
    {:error, Finding.at(env, block, "workflow name must be a string literal, got: #{Macro.to_string(name)}")}
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
    if Map.has_key?(seen, name) do
      {:error,
       Finding.at(env, stmt, "duplicate phase name #{inspect(name)}",
         hint: "phase names must be unique within a workflow"
       )}
    else
      build(rest, index + 1, [phase | acc], Map.put(seen, name, true), env, binding_env)
    end
  end

  defp finish_build(%GenericFanout{bind: bind} = fanout, _stmt, rest, index, acc, seen, env, binding_env)
       when not is_nil(bind) do
    build(
      rest,
      index + 1,
      [fanout | acc],
      seen,
      env,
      Map.put(binding_env, bind, {:fanout, fanout.address, :global})
    )
  end

  defp finish_build(%node{} = built, stmt, rest, index, acc, seen, env, binding_env)
       when node in [Return, Emit, EmitResult] do
    if rest == [] do
      build(rest, index + 1, [built | acc], seen, env, binding_env)
    else
      {:error,
       Finding.at(env, stmt, "`#{terminal_name(built)}` must be the final top-level node",
         hint: "a workflow terminates with `return`, `emit`, or `emit_result`"
       )}
    end
  end

  defp finish_build(node, _stmt, rest, index, acc, seen, env, binding_env) do
    build(rest, index + 1, [node | acc], seen, env, binding_env)
  end

  defp let_node({:let, _meta, [{:=, _eq_meta, [name, producer]}]} = form, address, env, binding_env) do
    with :ok <- binding_name(name, form, env),
         {:ok, node} <- node(producer, address, env, binding_env),
         :ok <- bindable_producer(node, form, env) do
      {:ok, node, Map.put(binding_env, name, binding_ref(node, address))}
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
  defp bindable_producer(%Refine{}, _form, _env), do: :ok

  defp bindable_producer(_other, form, env) do
    {:error,
     Finding.at(
       env,
       form,
       "`let` only binds `agent(...)`, `synthesize(...)`, or `refine(...)` producers"
     )}
  end

  defp binding_ref(%Refine{}, address), do: {:refine, address}
  defp binding_ref(_node, address), do: {:node, address}

  defp terminal_name(%Return{}), do: "return"
  defp terminal_name(%Emit{}), do: "emit"
  defp terminal_name(%EmitResult{}), do: "emit_result"

  # --- The closed combinator vocabulary ---

  defp node({:phase, _meta, [name]}, address, _env, _binding_env) when is_binary(name),
    do: {:ok, %Phase{address: address, name: name}}

  defp node({:log, _meta, [message]}, address, _env, _binding_env) when is_binary(message),
    do: {:ok, %Log{address: address, message: message}}

  defp node({:agent, _meta, [prompt]} = form, address, env, _binding_env) when is_binary(prompt) do
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
  defp node({:agent, _meta, [prompt, opts]} = form, address, env, _binding_env) when is_binary(prompt) do
    with {:ok, prompt} <- prompt_text(prompt, form, env, "agent prompt"),
         {:ok, kw} <- agent_options(opts, form, env),
         {:ok, schema} <- agent_schema(kw, form, env),
         {:ok, retries} <- agent_retries(kw, form, env),
         {:ok, label} <- agent_label(kw, form, env) do
      {:ok, %Agent{address: address, prompt: prompt, label: label, schema: schema, retries: retries}}
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
         {:ok, retries} <- agent_retries(kw, form, env),
         {:ok, label} <- agent_label(kw, form, env) do
      {:ok,
       %Agent{
         address: address,
         prompt: template,
         label: label,
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

  defp node({:emit_result, _meta, [binding]} = form, address, env, binding_env) do
    with {:ok, ref} <- emit_result_ref(binding, binding_env, form, env) do
      {:ok, %EmitResult{address: address, binding: binding, ref: ref}}
    end
  end

  # `parallel [agent(...), ...]` — a barrier fan-out over a literal list of agent
  # branches, optionally capped by `max_concurrency:`. Each branch is addressed
  # `address ++ [branch_index]`, so branches journal and key independently.
  defp node({:parallel, _meta, [branches]} = form, address, env, binding_env) when is_list(branches),
    do: parallel(branches, [], address, form, env, binding_env)

  defp node({:parallel, _meta, [branches, opts]} = form, address, env, binding_env) when is_list(branches),
    do: parallel(branches, opts, address, form, env, binding_env)

  # `pipeline items, [agent(...), ...]` — per-item lanes through ordered stages,
  # optionally capped by `max_concurrency:`. `items` is a literal list; the lanes
  # are expanded here into pre-addressed inert agents.
  defp node({:pipeline, _meta, [items, stages]} = form, address, env, binding_env),
    do: pipeline(items, stages, [], address, form, env, binding_env)

  defp node({:pipeline, _meta, [items, stages, opts]} = form, address, env, binding_env),
    do: pipeline(items, stages, opts, address, form, env, binding_env)

  # `loop max_iterations: N[, until: <predicate>][, on_exhausted: policy] do <body> end`
  # — the generic bounded loop core.
  defp node({:loop, _meta, args} = form, address, env, binding_env) do
    with {:ok, opts, block} <- loop_call(args, form, env),
         :ok <- only_keys(opts, [:max_iterations, :until, :on_exhausted], form, env),
         {:ok, cap} <- loop_iterations(opts, form, env, required: true),
         {:ok, until_pred} <- optional_predicate(opts, form, env, binding_env),
         {:ok, on_exhausted} <- on_exhausted(opts, form, env),
         {:ok, body} <-
           parse_body(block, address, form, env, binding_env,
             mode: :generic,
             header_until?: not is_nil(until_pred)
           ) do
      {:ok,
       %Loop{
         address: address,
         until: until_pred,
         body: body,
         max_iterations: cap,
         on_exhausted: on_exhausted
       }}
    end
  end

  # Legacy loop syntax lowers directly to the generic loop core. The runtime never
  # needs to know which spelling produced the tree.
  defp node({:while_budget, _meta, args} = form, address, env, binding_env) do
    with {:ok, opts, block} <- loop_call(args, form, env),
         :ok <- only_keys(opts, [:reserve, :until, :max_iterations], form, env),
         {:ok, reserve} <- required_integer(opts, :reserve, 0, form, env),
         {:ok, until_pred} <- optional_predicate(opts, form, env, binding_env),
         {:ok, cap} <- max_iterations(opts, form, env),
         {:ok, body} <- parse_body(block, address, form, env, binding_env, mode: :legacy) do
      budget_exhausted = %Predicate.Compare{
        op: :<=,
        left: %Predicate.BudgetRemaining{},
        right: reserve
      }

      until =
        case until_pred do
          nil -> budget_exhausted
          predicate -> %Predicate.AnyOf{predicates: [budget_exhausted, predicate]}
        end

      {:ok,
       %Loop{
         address: address,
         until: until,
         body: body,
         max_iterations: cap,
         on_exhausted: :stop
       }}
    end
  end

  defp node({:until_dry, _meta, args} = form, address, env, binding_env) do
    with {:ok, opts, block} <- loop_call(args, form, env),
         :ok <- only_keys(opts, [:rounds, :seen_by, :max_iterations], form, env),
         {:ok, rounds} <- required_integer(opts, :rounds, 1, form, env),
         {:ok, seen_by} <- seen_by_opt(opts, form, env),
         {:ok, cap} <- max_iterations(opts, form, env),
         {:ok, body} <- parse_body(block, address, form, env, binding_env, mode: :legacy),
         :ok <- require_collect(body, form, env) do
      {:ok,
       %Loop{
         address: address,
         until: %Predicate.Dry{rounds: rounds, seen_by: seen_by},
         body: body,
         max_iterations: cap,
         on_exhausted: :stop
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

  # `refine agent("draft"), reviewers: [reviewer(:a, "..."), reviewer(:b, "...")],
  # revise_with: agent("fix"), until: :unanimous, max_rounds: N` — V1 inline or
  # bound artifact input plus a static reviewer panel.
  defp node({:refine, _meta, [input, opts]} = form, address, env, binding_env) do
    with :ok <-
           refine_options(opts, form, env),
         {:ok, input} <- refine_input(input, binding_env, address ++ [0], form, env),
         {:ok, reviewers} <- refine_reviewers(opts, address, form, env),
         {:ok, reviser} <- refine_reviser(opts, address ++ [2], form, env),
         {:ok, until} <- refine_until(opts, form, env),
         {:ok, max_rounds} <- refine_max_rounds(opts, form, env),
         {:ok, on_non_convergence} <- refine_on_non_convergence(opts, form, env),
         {:ok, max_concurrency} <- refine_max_concurrency(opts, length(reviewers), form, env),
         {:ok, gates} <- refine_gates(opts, address, reviser, form, env) do
      {:ok,
       %Refine{
         address: address,
         input: input,
         reviewers: reviewers,
         reviser: reviser,
         until: until,
         max_rounds: max_rounds,
         on_non_convergence: on_non_convergence,
         max_concurrency: max_concurrency,
         gates: gates
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
  defp node({:synthesize, _meta, [inputs, prompt]} = form, address, env, _binding_env) when is_binary(prompt) do
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

  defp node({:synthesize, _meta, [inputs, {:<<>>, _, _parts}]} = form, _address, env, _binding_env) do
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

  # `fanout width: N[, max_concurrency: M][, on_zero: :complete | :fail] do <body> end`
  # accepts either one repeated agent lane or `lanes([[agent(...)], ...])` with a
  # literal width matching the explicit lane count.
  defp node({:fanout, _meta, args} = form, address, env, binding_env) do
    with {:ok, opts, block} <- loop_call(args, form, env),
         :ok <- only_keys(opts, [:width, :max_concurrency, :bind, :on_zero], form, env),
         {:ok, width} <- fanout_width(opts, form, env, binding_env),
         {:ok, cap} <- fanout_concurrency(opts, form, env),
         {:ok, bind} <- fanout_bind(opts, form, env, binding_env),
         {:ok, on_zero} <- fanout_on_zero(opts, form, env),
         {:ok, lanes} <- fanout_body(block, width, address, form, env, binding_env) do
      {:ok,
       %GenericFanout{
         address: address,
         width: width,
         lanes: lanes,
         bind: bind,
         max_concurrency: cap,
         on_zero: on_zero
       }}
    end
  end

  # Legacy `fan_out` syntax lowers directly to the generic fanout core. Its narrow
  # width grammar remains an authoring compatibility constraint, not a runtime type.
  defp node({:fan_out, _meta, args} = form, address, env, binding_env) do
    with {:ok, opts, block} <- loop_call(args, form, env),
         :ok <- only_keys(opts, [:width, :max_concurrency], form, env),
         {:ok, width} <- fan_out_width(opts, form, env),
         {:ok, cap} <- fanout_concurrency(opts, form, env),
         {:ok, lanes} <- legacy_fanout_lanes(block, width, address, form, env, binding_env) do
      {:ok,
       %GenericFanout{
         address: address,
         width: width,
         lanes: lanes,
         max_concurrency: cap
       }}
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

  defp node({:until, _meta, _args} = form, _address, env, _binding_env) do
    {:error, body_until_scope_finding(env, form)}
  end

  # A known combinator invoked with the wrong argument shape: recoverable finding,
  # located at the declaration site.
  defp node({combinator, _meta, _args} = form, _address, env, _binding_env) when combinator in @combinators,
    do: {:error, Finding.at(env, form, "`#{combinator}` was called with invalid arguments")}

  # --- Forbidden-form catalog: non-determinism and escape hatches return located
  # findings and are unrepresentable in a compiled tree. ---

  # Anonymous functions destroy total-validation, serialization, and resume.
  defp node({:fn, _meta, _clauses} = form, _address, env, _binding_env) do
    {:error,
     Finding.at(env, form, "anonymous functions are not part of the workflow vocabulary",
       hint: "a workflow is inert, serializable data — it cannot capture a closure"
     )}
  end

  # Any call into an external module — `:rand.*`, `System.*`, `Enum.*`, ... .
  defp node({{:., _, [_module, _fun]}, _meta, _args} = form, _address, env, _binding_env) do
    {:error,
     Finding.at(env, form, "calls to external modules are not part of the workflow vocabulary",
       hint: "a workflow must be deterministic and self-contained (no #{callee(form)})"
     )}
  end

  # An unknown bare call: reject with a closed-vocabulary suggestion.
  defp node({name, _meta, args} = form, _address, env, _binding_env) when is_atom(name) and is_list(args) do
    {:error, Finding.at(env, form, "unknown combinator `#{name}`", hint: suggest(name))}
  end

  # Anything else — a stray literal, a variable, an operator: outside the vocabulary.
  defp node(form, _address, env, _binding_env) do
    {:error,
     Finding.at(env, form, "unknown workflow form outside the combinator vocabulary",
       hint: "expected one of: #{vocabulary()}"
     )}
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
        if Keyword.has_key?(kw, :retries) do
          {:error,
           Finding.at(env, form, "`agent` with `retries:` requires a `schema:`",
             hint: "schema-backed agents fail closed; give schema: %{...}"
           )}
        else
          {:ok, nil}
        end
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

      {:ok, n} when is_integer(n) and n >= 0 and n <= @max_agent_retries ->
        {:ok, n}

      {:ok, n} when is_integer(n) and n > @max_agent_retries ->
        {:error, Finding.at(env, form, "`agent` retries must be at most #{@max_agent_retries}")}

      {:ok, _} ->
        {:error, Finding.at(env, form, "`agent` retries must be a non-negative integer")}
    end
  end

  defp agent_label(kw, form, env) do
    case Keyword.fetch(kw, :label) do
      :error ->
        {:ok, nil}

      {:ok, label} when is_binary(label) ->
        prompt_text(label, form, env, "agent label")

      {:ok, _} ->
        {:error, Finding.at(env, form, "`agent` label must be a string literal")}
    end
  end

  # --- Static fan-out combinators (parallel / pipeline) ---

  defp parallel([], _opts, _address, form, env, _binding_env) do
    {:error,
     Finding.at(env, form, "`parallel` requires at least one branch", hint: ~s{parallel [agent("..."), agent("...")]})}
  end

  defp parallel(branches, opts, address, form, env, binding_env) do
    with {:ok, cap} <- concurrency_opt(opts, form, env),
         {:ok, nodes} <- agent_branches(branches, address, env, binding_env) do
      {:ok, %Parallel{address: address, branches: nodes, max_concurrency: cap}}
    end
  end

  # Each branch must be a single `agent` turn (the concurrency shape fans out agent
  # turns). Reuse `node/4` so a malformed branch returns the same located diagnostic
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
       Finding.at(env, form, "invalid fan-out options", hint: "the only option is `max_concurrency: <pos integer>`")}
    end
  end

  # Materialize a **verified-literal** AST into its runtime value. Total over the
  # literal subset `Macro.quoted_literal?/1` admits; used only after that gate, so
  # the compiled node carries plain data (a map), never a fragment of AST.
  defp materialize({:%{}, _, pairs}), do: Map.new(pairs, fn {k, v} -> {materialize(k), materialize(v)} end)

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
  defp parse_body(block, loop_address, form, env, binding_env, opts) do
    mode = Keyword.get(opts, :mode, :legacy)
    header_until? = Keyword.get(opts, :header_until?, false)

    with {:ok, body} <-
           build_body(
             statements(block),
             loop_address,
             0,
             [],
             %{},
             env,
             binding_env,
             mode
           ) do
      body_until_count = Enum.count(body, &match?(%Until{}, &1))

      cond do
        body == [] ->
          {:error, Finding.at(env, form, "a loop body must contain at least one node")}

        header_until? and body_until_count > 0 ->
          {:error,
           Finding.at(
             env,
             form,
             "a generic loop must not combine header `until:` with body `until(...)`"
           )}

        body_until_count > 1 ->
          {:error, Finding.at(env, form, "a generic loop body may contain at most one `until(...)`")}

        true ->
          {:ok, body}
      end
    end
  end

  defp build_body([], _loop_address, _index, acc, _seen, _env, _binding_env, _mode), do: {:ok, Enum.reverse(acc)}

  defp build_body([stmt | rest], loop_address, index, acc, seen, env, binding_env, mode) do
    case body_node(stmt, loop_address ++ [index], env, binding_env, mode) do
      {:ok, %Phase{name: name} = phase} ->
        if Map.has_key?(seen, name) do
          {:error, Finding.at(env, stmt, "duplicate phase name #{inspect(name)}")}
        else
          build_body(
            rest,
            loop_address,
            index + 1,
            [phase | acc],
            Map.put(seen, name, true),
            env,
            binding_env,
            mode
          )
        end

      {:ok, %GenericFanout{bind: bind} = fanout} when mode == :generic and not is_nil(bind) ->
        next_binding_env =
          Map.put(binding_env, bind, {:fanout, fanout.address, {:loop_local, loop_address}})

        build_body(
          rest,
          loop_address,
          index + 1,
          [fanout | acc],
          seen,
          env,
          next_binding_env,
          mode
        )

      {:ok, node} ->
        build_body(rest, loop_address, index + 1, [node | acc], seen, env, binding_env, mode)

      {:error, _} = err ->
        err
    end
  end

  # A loop body permits the body vocabulary plus `collect`; loops, fan-out, and
  # `return` are rejected here (keeping the iteration key a single integer), while
  # closures/external calls return findings through the shared forbidden-form catalog.
  defp body_node({:collect, _meta, [opts]} = form, address, env, _binding_env, _mode),
    do: collect(opts, form, address, env)

  defp body_node({:collect, _meta, _args} = form, _address, env, _binding_env, _mode),
    do: {:error, Finding.at(env, form, "`collect` requires `into: :name`")}

  defp body_node({:until, _meta, [predicate_ast]} = form, address, env, binding_env, :generic) do
    with {:ok, predicate} <- Predicate.parse(predicate_ast, env, binding_env),
         :ok <- reject_body_until_dry(predicate, form, env) do
      {:ok, %Until{address: address, predicate: predicate}}
    end
  end

  defp body_node({:until, _meta, _args} = form, _address, env, _binding_env, _mode),
    do: {:error, body_until_scope_finding(env, form)}

  defp body_node({:let, _meta, _args} = form, _address, env, _binding_env, _mode),
    do: {:error, Finding.at(env, form, "`let` is not allowed inside a loop body")}

  defp body_node({:emit, _meta, _args} = form, _address, env, _binding_env, _mode),
    do: {:error, Finding.at(env, form, "`emit` is not allowed inside a loop body")}

  defp body_node({:emit_result, _meta, _args} = form, _address, env, _binding_env, _mode),
    do: {:error, Finding.at(env, form, "`emit_result` is not allowed inside a loop body")}

  defp body_node({combinator, _meta, _args} = form, _address, env, _binding_env, :legacy)
       when combinator in [
              :loop,
              :while_budget,
              :until_dry,
              :parallel,
              :pipeline,
              :return,
              :verify,
              :refine,
              :judge,
              :synthesize,
              :fanout,
              :fan_out
            ] do
    {:error,
     Finding.at(env, form, "`#{combinator}` is not allowed inside a loop body",
       hint: "a loop body may contain: #{Enum.join(@legacy_body_combinators, ", ")}"
     )}
  end

  defp body_node({combinator, _meta, _args} = form, _address, env, _binding_env, :generic)
       when combinator in [
              :loop,
              :while_budget,
              :until_dry,
              :parallel,
              :pipeline,
              :return,
              :verify,
              :refine,
              :judge,
              :synthesize,
              :fan_out
            ] do
    {:error,
     Finding.at(env, form, "`#{combinator}` is not allowed inside a loop body",
       hint: "a generic loop body may contain: #{Enum.join(@generic_body_combinators, ", ")}"
     )}
  end

  defp body_node(stmt, address, env, binding_env, _mode) do
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
      {:error, Finding.at(env, form, "invalid loop options", hint: "allowed options: #{Enum.join(allowed, ", ")}")}
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

  defp optional_predicate(opts, _form, env, binding_env) do
    case Keyword.fetch(opts, :until) do
      :error ->
        {:ok, nil}

      {:ok, ast} ->
        with {:ok, predicate} <- Predicate.parse(ast, env, binding_env),
             {:ok, _seen_by} <- dry_seen_by(predicate, ast, env) do
          {:ok, predicate}
        end
    end
  end

  defp dry_seen_by(predicate, ast, env) do
    case Predicate.dry_seen_by(predicate) do
      {:ok, seen_by} ->
        {:ok, seen_by}

      {:error, :conflicting_seen_by} ->
        {:error, Finding.at(env, ast, "conflicting `dry` seen_by lists in `until:` predicate")}
    end
  end

  defp reject_body_until_dry(predicate, form, env) do
    if contains_dry?(predicate) do
      {:error, Finding.at(env, form, "body `until` predicate must not contain `dry`")}
    else
      :ok
    end
  end

  defp contains_dry?(%Predicate.Dry{}), do: true

  defp contains_dry?(%Predicate.AllOf{predicates: predicates}), do: Enum.any?(predicates, &contains_dry?/1)

  defp contains_dry?(%Predicate.AnyOf{predicates: predicates}), do: Enum.any?(predicates, &contains_dry?/1)

  defp contains_dry?(_predicate), do: false

  defp on_exhausted(opts, form, env) do
    case Keyword.fetch(opts, :on_exhausted) do
      :error ->
        {:ok, :stop}

      {:ok, policy} when policy in [:stop, :fail, :accept_current] ->
        {:ok, policy}

      {:ok, _} ->
        {:error, Finding.at(env, form, "`on_exhausted` must be one of :stop, :fail, or :accept_current")}
    end
  end

  defp max_iterations(opts, form, env) do
    loop_iterations(opts, form, env, required: false)
  end

  defp loop_iterations(opts, form, env, required: required?) do
    case Keyword.fetch(opts, :max_iterations) do
      :error when required? ->
        {:error, Finding.at(env, form, "a loop requires `max_iterations:`")}

      :error ->
        {:ok, @default_max_iterations}

      {:ok, n} when is_integer(n) and n > 0 and n <= @max_loop_iterations ->
        {:ok, n}

      {:ok, _} ->
        {:error, Finding.at(env, form, "`max_iterations` must be between 1 and #{@max_loop_iterations}")}
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

  defp body_until_scope_finding(env, form) do
    Finding.at(env, form, "`until` is only allowed inside a generic `loop` body",
      hint: "use `loop max_iterations: N do ... until(predicate) ... end`"
    )
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
          {:error, Finding.at(env, form, "`verify` `lenses:` must be a list of perspective atoms")}
        end

      {:error, {:ok, _bad}} ->
        {:error, Finding.at(env, form, "`verify` `lenses:` must be a non-empty list of perspective atoms")}

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

  defp refine_input({:agent, _meta, _args} = input, _binding_env, address, form, env),
    do: refine_producer(input, address, form, env)

  defp refine_input(name, binding_env, _address, form, env) when is_atom(name) do
    case Map.fetch(binding_env, name) do
      {:ok, ref} ->
        {:ok, {:binding, name, ref}}

      :error ->
        {:error,
         Finding.at(env, form, "`refine` input binding #{inspect(name)} is not in scope",
           hint: "bind it earlier with `let #{inspect(name)} = agent(...)`"
         )}
    end
  end

  defp refine_input(_input, _binding_env, _address, form, env) do
    {:error,
     Finding.at(env, form, "`refine` V1 input must be an inline `agent(\"...\")` or binding atom",
       hint: "use `refine agent(\"Draft.\"), ...` or `let :draft = ...` followed by `refine :draft, ...`"
     )}
  end

  defp refine_options(opts, form, env) do
    cond do
      not keyword_literal?(opts) or not Keyword.keyword?(opts) ->
        {:error,
         Finding.at(env, form, "`refine` options must be a literal keyword list",
           hint: "allowed options: #{Enum.join(@refine_allowed_options, ", ")}"
         )}

      unknown = Enum.find(Keyword.keys(opts), &(&1 not in @refine_allowed_options)) ->
        {:error,
         Finding.at(env, form, "`refine` option `#{unknown}:` is not allowed",
           hint: "allowed options: #{Enum.join(@refine_allowed_options, ", ")}"
         )}

      duplicate_required = Enum.find(@refine_required_options, &(keyword_count(opts, &1) > 1)) ->
        {:error,
         Finding.at(
           env,
           form,
           "`refine` option `#{duplicate_required}:` must appear exactly once"
         )}

      missing_required = Enum.find(@refine_required_options, &(keyword_count(opts, &1) == 0)) ->
        {:error,
         Finding.at(
           env,
           form,
           "`refine` option `#{missing_required}:` must appear exactly once"
         )}

      duplicate_optional = Enum.find(@refine_optional_options, &(keyword_count(opts, &1) > 1)) ->
        {:error,
         Finding.at(
           env,
           form,
           "`refine` option `#{duplicate_optional}:` must appear at most once"
         )}

      true ->
        :ok
    end
  end

  defp keyword_count(opts, key), do: Enum.count(opts, fn {candidate, _value} -> candidate == key end)

  defp refine_producer({:agent, _meta, [prompt]} = form, address, _refine_form, env) when is_binary(prompt) do
    with {:ok, prompt} <- prompt_text(prompt, form, env, "refine producer prompt") do
      {:ok,
       {:producer,
        %Agent{
          address: address,
          prompt: prompt,
          schema: @artifact_schema,
          retries: @default_retries
        }}}
    end
  end

  defp refine_producer({:agent, _meta, [{:<<>>, _, _parts}]} = form, _address, _refine_form, env),
    do: {:error, interpolation_finding(form, env, "refine producer prompt")}

  defp refine_producer(_input, _address, form, env) do
    {:error,
     Finding.at(env, form, "`refine` inline input must be `agent(\"...\")`",
       hint: "bound input must be passed as a binding atom, e.g. `refine :draft, ...`"
     )}
  end

  defp refine_reviewer_name(name, form, env) when is_atom(name) do
    if String.match?(Atom.to_string(name), ~r/^[a-z_][a-zA-Z0-9_]*$/) do
      {:ok, name}
    else
      {:error,
       Finding.at(env, form, "inadmissible reviewer name #{inspect(name)}",
         hint: "reviewer names must look like `:spec` or `:runtime`"
       )}
    end
  end

  defp refine_reviewer_name(_name, form, env),
    do: {:error, Finding.at(env, form, "`reviewer/2` name must be an atom literal")}

  defp refine_reviewers(opts, address, form, env) do
    case Keyword.fetch(opts, :reviewers) do
      {:ok, reviewers} when is_list(reviewers) ->
        reviewers
        |> Enum.with_index()
        |> Enum.reduce_while({:ok, []}, fn {reviewer, index}, {:ok, acc} ->
          case refine_reviewer(reviewer, address, index, env) do
            {:ok, reviewer} -> {:cont, {:ok, [reviewer | acc]}}
            {:error, _} = err -> {:halt, err}
          end
        end)
        |> case do
          {:ok, parsed} ->
            parsed = Enum.reverse(parsed)

            cond do
              length(parsed) < 2 ->
                {:error, Finding.at(env, form, "`refine` requires at least two reviewers")}

              duplicate_reviewer_name?(parsed) ->
                {:error, Finding.at(env, form, "`refine` reviewer names must be unique")}

              true ->
                {:ok, parsed}
            end

          {:error, _} = err ->
            err
        end

      {:ok, _} ->
        {:error, Finding.at(env, form, "`refine` reviewers must be a literal reviewer list")}

      :error ->
        {:error, Finding.at(env, form, "`refine` requires `reviewers:`")}
    end
  end

  defp refine_reviewer({:reviewer, _meta, [name, prompt]} = form, address, index, env) when is_binary(prompt) do
    refine_reviewer(form, name, prompt, [], address, index, env)
  end

  defp refine_reviewer({:reviewer, _meta, [name, prompt, opts]} = form, address, index, env) when is_binary(prompt) do
    refine_reviewer(form, name, prompt, opts, address, index, env)
  end

  defp refine_reviewer({:reviewer, _meta, [_name, {:<<>>, _, _parts} | _rest]} = form, _address, _index, env),
    do: {:error, interpolation_finding(form, env, "reviewer prompt")}

  defp refine_reviewer(_reviewer, _address, _index, env),
    do:
      {:error, Finding.at(env, nil, "`reviewers:` entries must be `reviewer(:name, \"prompt\", adapter: :findings_v1)`")}

  defp refine_reviewer(form, name, prompt, opts, address, index, env) do
    refine_reviewer_at(form, name, prompt, opts, address ++ [1, index], index, env)
  end

  defp refine_reviewer_at(form, name, prompt, opts, agent_address, index, env) do
    with {:ok, name} <- refine_reviewer_name(name, form, env),
         {:ok, prompt} <- prompt_text(prompt, form, env, "reviewer prompt"),
         {:ok, adapter} <- reviewer_adapter(opts, form, env) do
      agent = %Agent{
        address: agent_address,
        prompt: prompt,
        label: Atom.to_string(name),
        schema: ReviewerAdapter.schema(adapter),
        retries: 0
      }

      {:ok,
       %Reviewer{
         index: index,
         name: name,
         prompt: prompt,
         adapter: adapter,
         agent: agent
       }}
    end
  end

  defp reviewer_adapter([], _form, _env), do: {:ok, ReviewerAdapter.default()}

  defp reviewer_adapter(opts, form, env) do
    cond do
      not keyword_literal?(opts) or not Keyword.keyword?(opts) ->
        {:error,
         Finding.at(env, form, "`reviewer` options must be a literal keyword list",
           hint: "allowed option: adapter: #{inspect(ReviewerAdapter.all())}"
         )}

      unknown = Enum.find(Keyword.keys(opts), &(&1 != :adapter)) ->
        {:error,
         Finding.at(env, form, "`reviewer` options may only include `adapter:`",
           hint: "`#{unknown}:` is not a reviewer option"
         )}

      keyword_count(opts, :adapter) > 1 ->
        {:error, Finding.at(env, form, "`reviewer` option `adapter:` must appear at most once")}

      true ->
        case Keyword.fetch(opts, :adapter) do
          :error -> {:ok, ReviewerAdapter.default()}
          {:ok, adapter} when is_atom(adapter) -> validate_reviewer_adapter(adapter, form, env)
          {:ok, _other} -> unsupported_reviewer_adapter(nil, form, env)
        end
    end
  end

  defp validate_reviewer_adapter(adapter, form, env) do
    if ReviewerAdapter.known?(adapter) do
      {:ok, adapter}
    else
      unsupported_reviewer_adapter(adapter, form, env)
    end
  end

  defp unsupported_reviewer_adapter(adapter, form, env) do
    {:error,
     Finding.at(env, form, "unsupported reviewer adapter #{inspect(adapter)}",
       hint: "supported adapters: #{Enum.map_join(ReviewerAdapter.all(), ", ", &inspect/1)}"
     )}
  end

  defp duplicate_reviewer_name?(reviewers) do
    names = Enum.map(reviewers, & &1.name)
    Enum.uniq(names) != names
  end

  defp refine_reviser(opts, address, form, env) do
    case Keyword.fetch(opts, :revise_with) do
      {:ok, {:agent, _meta, [prompt]} = agent_form} when is_binary(prompt) ->
        with {:ok, prompt} <- prompt_text(prompt, agent_form, env, "refine reviser prompt") do
          {:ok,
           %Agent{
             address: address,
             prompt: prompt,
             schema: @artifact_schema,
             retries: @default_retries
           }}
        end

      {:ok, {:agent, _meta, [{:<<>>, _, _parts}]} = agent_form} ->
        {:error, interpolation_finding(agent_form, env, "refine reviser prompt")}

      {:ok, _} ->
        {:error, Finding.at(env, form, "`refine` `revise_with:` must be `agent(\"...\")`")}

      :error ->
        {:error, Finding.at(env, form, "`refine` requires `revise_with:`")}
    end
  end

  defp refine_until(opts, form, env) do
    case Keyword.fetch(opts, :until) do
      {:ok, :unanimous} -> {:ok, :unanimous}
      {:ok, _} -> {:error, Finding.at(env, form, "`refine` `until:` must be `:unanimous`")}
      :error -> {:error, Finding.at(env, form, "`refine` requires `until: :unanimous`")}
    end
  end

  defp refine_max_rounds(opts, form, env) do
    case Keyword.fetch(opts, :max_rounds) do
      {:ok, n} when is_integer(n) and n > 0 ->
        {:ok, n}

      {:ok, _} ->
        {:error, Finding.at(env, form, "`refine` `max_rounds:` must be a positive integer")}

      :error ->
        {:error, Finding.at(env, form, "`refine` requires `max_rounds:`")}
    end
  end

  defp refine_on_non_convergence(opts, form, env) do
    case Keyword.fetch(opts, :on_non_convergence) do
      :error ->
        {:ok, :fail}

      {:ok, value} when value in [:fail, :accept_current] ->
        {:ok, value}

      {:ok, _} ->
        {:error,
         Finding.at(
           env,
           form,
           "`refine` `on_non_convergence:` must be `:fail` or `:accept_current`"
         )}
    end
  end

  defp refine_max_concurrency(opts, reviewer_count, form, env) do
    case Keyword.fetch(opts, :max_concurrency) do
      :error ->
        {:ok, reviewer_count}

      {:ok, n} when is_integer(n) and n > 0 ->
        {:ok, n}

      {:ok, _} ->
        {:error, Finding.at(env, form, "`refine` `max_concurrency:` must be a positive integer")}
    end
  end

  defp refine_gates(opts, address, %Agent{} = reviser, form, env) do
    case Keyword.fetch(opts, :gates) do
      :error ->
        {:ok, %{}}

      {:ok, gates} ->
        cond do
          not (is_list(gates) and Keyword.keyword?(gates) and keyword_literal?(gates)) ->
            {:error, Finding.at(env, form, "`refine` `gates:` must be a literal keyword list")}

          unknown = Enum.find(Keyword.keys(gates), &(&1 not in @refine_gate_options)) ->
            {:error,
             Finding.at(env, form, "`refine` gate `#{unknown}:` is not allowed",
               hint: "allowed gates: #{Enum.join(@refine_gate_options, ", ")}"
             )}

          duplicate = Enum.find(@refine_gate_options, &(keyword_count(gates, &1) > 1)) ->
            {:error, Finding.at(env, form, "`refine` gate `#{duplicate}:` must appear at most once")}

          true ->
            build_refine_gates(gates, address, reviser, form, env)
        end
    end
  end

  defp build_refine_gates(gates, address, %Agent{} = reviser, form, env) do
    with {:ok, acc} <- maybe_cold_read_gate(gates, address, form, env),
         {:ok, acc} <- maybe_repair_gate(gates, address, reviser, acc, form, env) do
      maybe_halt_gate(gates, acc, form, env)
    end
  end

  defp maybe_cold_read_gate(gates, address, form, env) do
    case Keyword.fetch(gates, :cold_read) do
      :error ->
        {:ok, %{}}

      {:ok, opts} ->
        with {:ok, gate} <- cold_read_gate(opts, address, form, env) do
          {:ok, %{cold_read: gate}}
        end
    end
  end

  defp cold_read_gate(opts, address, form, env) do
    cond do
      not (is_list(opts) and Keyword.keyword?(opts) and keyword_literal?(opts)) ->
        {:error, Finding.at(env, form, "`cold_read:` gate must be [reviewer: reviewer(...), when: gate]")}

      unknown = Enum.find(Keyword.keys(opts), &(&1 not in [:reviewer, :when])) ->
        {:error, Finding.at(env, form, "`cold_read:` gate option `#{unknown}:` is not allowed")}

      keyword_count(opts, :reviewer) > 1 ->
        {:error, Finding.at(env, form, "`cold_read:` gate `reviewer:` must appear exactly once")}

      keyword_count(opts, :when) > 1 ->
        {:error, Finding.at(env, form, "`cold_read:` gate `when:` must appear exactly once")}

      not Keyword.has_key?(opts, :reviewer) ->
        {:error, Finding.at(env, form, "`cold_read:` requires `reviewer:`")}

      not Keyword.has_key?(opts, :when) ->
        {:error, Finding.at(env, form, "`cold_read:` requires `when:`")}

      true ->
        with {:ok, reviewer} <-
               cold_read_reviewer(Keyword.fetch!(opts, :reviewer), address ++ [3], env),
             {:ok, predicate} <- gate_predicate(Keyword.fetch!(opts, :when), form, env) do
          {:ok, %{predicate: predicate, reviewer: reviewer}}
        end
    end
  end

  defp cold_read_reviewer({:reviewer, _meta, [name, prompt]} = form, address, env) when is_binary(prompt) do
    refine_reviewer_at(form, name, prompt, [], address, nil, env)
  end

  defp cold_read_reviewer({:reviewer, _meta, [name, prompt, opts]} = form, address, env) when is_binary(prompt) do
    refine_reviewer_at(form, name, prompt, opts, address, nil, env)
  end

  defp cold_read_reviewer({:reviewer, _meta, [_name, {:<<>>, _, _parts} | _rest]} = form, _address, env),
    do: {:error, interpolation_finding(form, env, "cold-read reviewer prompt")}

  defp cold_read_reviewer(_reviewer, _address, env) do
    {:error,
     Finding.at(
       env,
       nil,
       "`cold_read:` `reviewer:` must be `reviewer(:name, \"prompt\", adapter: :findings_v1)`"
     )}
  end

  defp maybe_repair_gate(gates, address, %Agent{} = reviser, acc, form, env) do
    case Keyword.fetch(gates, :repair_when) do
      :error ->
        {:ok, acc}

      {:ok, predicate_ast} ->
        with {:ok, predicate} <- gate_predicate(predicate_ast, form, env) do
          {:ok,
           Map.put(acc, :repair, %{
             predicate: predicate,
             agent: %{reviser | address: address ++ [4]}
           })}
        end
    end
  end

  defp maybe_halt_gate(gates, acc, form, env) do
    case Keyword.fetch(gates, :halt_when) do
      :error ->
        {:ok, acc}

      {:ok, predicate_ast} ->
        with {:ok, predicate} <- gate_predicate(predicate_ast, form, env) do
          {:ok, Map.put(acc, :halt, %{predicate: predicate})}
        end
    end
  end

  defp gate_predicate({:path_exists, _meta, [pointer]} = form, _parent_form, env),
    do: gate_pointer_predicate(:path_exists, pointer, form, env)

  defp gate_predicate({:path_non_empty, _meta, [pointer]} = form, _parent_form, env),
    do: gate_pointer_predicate(:path_non_empty, pointer, form, env)

  defp gate_predicate({:path_equals, _meta, [pointer, literal]} = form, _parent_form, env) do
    with {:ok, pointer} <- gate_pointer(pointer, form, env),
         {:ok, literal} <- gate_literal_to_json(literal, form, env) do
      {:ok, {:path_equals, pointer, literal}}
    end
  end

  defp gate_predicate({op, _meta, [{:path_count, _count_meta, [pointer]} = count_form, right]}, _parent_form, env)
       when op in @gate_compare_ops and is_integer(right) do
    with {:ok, pointer} <- gate_pointer(pointer, count_form, env) do
      {:ok, {:path_count, pointer, op, right}}
    end
  end

  defp gate_predicate({_op, _meta, [{:path_count, _count_meta, [_pointer]}, _right]} = form, _parent_form, env) do
    {:error, Finding.at(env, form, "`path_count` gate must compare with one of >, <, >=, <=, ==")}
  end

  defp gate_predicate({name, _meta, _args} = form, _parent_form, env) when is_atom(name) do
    {:error, Finding.at(env, form, "unknown refine gate predicate `#{name}`")}
  end

  defp gate_predicate(_predicate, form, env) do
    {:error, Finding.at(env, form, "unknown refine gate predicate")}
  end

  defp gate_pointer_predicate(kind, pointer, form, env) do
    with {:ok, pointer} <- gate_pointer(pointer, form, env) do
      {:ok, {kind, pointer}}
    end
  end

  defp gate_pointer(pointer, form, env) when is_binary(pointer) do
    if Gate.valid_pointer?(pointer) do
      {:ok, pointer}
    else
      {:error,
       Finding.at(
         env,
         form,
         ~s(gate JSON pointer must be "" or start with "/" and use RFC 6901 escapes)
       )}
    end
  end

  defp gate_pointer(_pointer, form, env) do
    {:error, Finding.at(env, form, "gate JSON pointer must be a literal string")}
  end

  defp gate_literal_to_json(nil, _form, _env), do: {:ok, nil}
  defp gate_literal_to_json(value, _form, _env) when is_boolean(value), do: {:ok, value}
  defp gate_literal_to_json(value, _form, _env) when is_integer(value), do: {:ok, value}
  defp gate_literal_to_json(value, _form, _env) when is_binary(value), do: {:ok, value}

  defp gate_literal_to_json(value, _form, _env) when is_atom(value), do: {:ok, Atom.to_string(value)}

  defp gate_literal_to_json(values, form, env) when is_list(values) do
    values
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, acc} ->
      case gate_literal_to_json(value, form, env) do
        {:ok, json} -> {:cont, {:ok, [json | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      {:error, _} = err -> err
    end
  end

  defp gate_literal_to_json({:%{}, _meta, pairs}, form, env) do
    pairs
    |> Enum.reduce_while({:ok, %{}, MapSet.new()}, fn {key_ast, value_ast}, {:ok, acc, seen} ->
      with {:ok, key} <- gate_literal_key(key_ast, form, env),
           false <- MapSet.member?(seen, key),
           {:ok, value} <- gate_literal_to_json(value_ast, form, env) do
        {:cont, {:ok, Map.put(acc, key, value), MapSet.put(seen, key)}}
      else
        true ->
          {:halt, {:error, Finding.at(env, form, "gate literal has duplicate object key")}}

        {:error, _} = err ->
          {:halt, err}
      end
    end)
    |> case do
      {:ok, acc, _seen} -> {:ok, acc}
      {:error, _} = err -> err
    end
  end

  defp gate_literal_to_json(_value, form, env) do
    {:error, Finding.at(env, form, "`path_equals` gate literal is not JSON-encodable")}
  end

  defp gate_literal_key(key, _form, _env) when is_binary(key), do: {:ok, key}
  defp gate_literal_key(key, _form, _env) when is_atom(key), do: {:ok, Atom.to_string(key)}

  defp gate_literal_key(_key, form, env) do
    {:error, Finding.at(env, form, "gate literal object keys must be strings or atoms")}
  end

  defp judge_candidates(candidates, form, env) do
    if is_list(candidates) and Macro.quoted_literal?(candidates) do
      case materialize(candidates) do
        [] -> {:error, Finding.at(env, form, "`judge` requires at least one candidate")}
        list -> {:ok, list}
      end
    else
      {:error,
       Finding.at(env, form, "`judge` candidates must be a literal list",
         hint: ~s|pass a compile-time list, e.g. judge ["a", "b"], by: [:quality], pick: :max_score|
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
        {:error, Finding.at(env, form, "`judge` `by:` must be a non-empty list of criterion atoms")}

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
        {:error, Finding.at(env, form, "`judge` requires `pick: :max_score` or `pick: :min_score`")}
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

  defp fanout_width(opts, form, env, binding_env) do
    case Keyword.fetch(opts, :width) do
      {:ok, n} when is_integer(n) and n >= 0 and n <= @max_fanout_width ->
        {:ok, n}

      {:ok, n} when is_integer(n) and n > @max_fanout_width ->
        {:error, Finding.at(env, form, "`fanout` literal width must be at most #{@max_fanout_width}")}

      {:ok, {:budget_slices, _meta, [budget_opts]}} ->
        fanout_budget_slices_width(budget_opts, form, env)

      {:ok, {:path_count, _meta, [binding, pointer, path_opts]} = path_form} ->
        fanout_path_count_width(binding, pointer, path_opts, path_form, env, binding_env)

      {:ok, {:path_count, _meta, _args}} ->
        {:error,
         Finding.at(env, form, "`path_count` fanout width requires `max:`",
           hint: ~s|path_count(:items, "/rows", max: 100)|
         )}

      {:ok, _} ->
        {:error,
         Finding.at(env, form, "`fanout` width must be a closed WidthExpr",
           hint: ~s|use an integer, budget_slices(per: N, max: M), or path_count(:binding, "/pointer", max: M)|
         )}

      :error ->
        {:error, Finding.at(env, form, "`fanout` requires `width:`")}
    end
  end

  defp fanout_budget_slices_width(opts, form, env) do
    with {:ok, opts} <-
           width_keyword(opts, [:per, :max], [:per], form, env, "`budget_slices`"),
         {:ok, per} <- positive_width_integer(Keyword.fetch!(opts, :per), :per, form, env),
         {:ok, max} <- optional_positive_width_integer(Keyword.get(opts, :max), :max, form, env) do
      {:ok, %BudgetSlices{per: per, max: max}}
    end
  end

  defp fanout_path_count_width(binding, pointer, opts, form, env, binding_env) do
    with {:ok, opts} <- width_keyword(opts, [:max], [:max], form, env, "`path_count`"),
         {:ok, binding, ref} <- fanout_width_binding_ref(binding, form, env, binding_env),
         {:ok, pointer} <- fanout_width_pointer(pointer, form, env),
         {:ok, max} <- positive_width_integer(Keyword.fetch!(opts, :max), :max, form, env) do
      {:ok, %PathCount{binding: binding, ref: ref, pointer: pointer, max: max}}
    end
  end

  defp width_keyword(opts, allowed, required, form, env, label) do
    keys = if Keyword.keyword?(opts), do: Keyword.keys(opts), else: []
    duplicates = keys -- Enum.uniq(keys)

    cond do
      not (keyword_literal?(opts) and Keyword.keyword?(opts)) ->
        {:error, Finding.at(env, form, "#{label} options must be a keyword list")}

      duplicates != [] ->
        {:error, Finding.at(env, form, "#{label} has duplicate option #{inspect(hd(duplicates))}")}

      Enum.any?(keys, &(&1 not in allowed)) ->
        {:error, Finding.at(env, form, "invalid #{label} options", hint: "allowed options: #{Enum.join(allowed, ", ")}")}

      Enum.any?(required, &(&1 not in keys)) ->
        missing = required -- keys
        {:error, Finding.at(env, form, "#{label} requires `#{hd(missing)}:`")}

      true ->
        {:ok, opts}
    end
  end

  defp fanout_width_binding_ref(binding, form, env, binding_env)
       when is_atom(binding) and not is_boolean(binding) and not is_nil(binding) do
    case Map.fetch(binding_env, binding) do
      {:ok, {:fanout, _address, {:loop_local, _loop_address}}} ->
        {:error, Finding.at(env, form, "`path_count` fanout width requires a global binding")}

      {:ok, ref} ->
        if binding_ref?(ref) do
          {:ok, binding, ref}
        else
          {:error, Finding.at(env, form, "binding #{inspect(binding)} does not resolve to a binding ref")}
        end

      :error ->
        {:error, Finding.at(env, form, "unknown binding #{inspect(binding)}")}
    end
  end

  defp fanout_width_binding_ref(_binding, form, env, _binding_env),
    do: {:error, Finding.at(env, form, "`path_count` binding must be a literal binding atom")}

  defp fanout_width_pointer(pointer, form, env) when is_binary(pointer) do
    if Gate.valid_pointer?(pointer) do
      {:ok, pointer}
    else
      {:error,
       Finding.at(
         env,
         form,
         ~s(`path_count` JSON pointer must be "" or start with "/" and use RFC 6901 escapes)
       )}
    end
  end

  defp fanout_width_pointer(_pointer, form, env),
    do: {:error, Finding.at(env, form, "`path_count` JSON pointer must be a literal string")}

  defp positive_width_integer(n, _key, _form, _env) when is_integer(n) and n > 0, do: {:ok, n}

  defp positive_width_integer(_value, key, form, env),
    do: {:error, Finding.at(env, form, "`#{key}` must be a positive integer")}

  defp optional_positive_width_integer(nil, _key, _form, _env), do: {:ok, nil}

  defp optional_positive_width_integer(value, key, form, env), do: positive_width_integer(value, key, form, env)

  defp binding_ref?({kind, address}) when kind in [:node, :map, :refine] and is_list(address), do: address?(address)

  defp binding_ref?({:fanout, address, :global}) when is_list(address), do: address?(address)

  defp binding_ref?({:fanout, address, {:loop_local, loop_address}}) when is_list(address) and is_list(loop_address),
    do: address?(address) and address?(loop_address)

  defp binding_ref?(_ref), do: false

  defp address?(address), do: Enum.all?(address, &(is_integer(&1) and &1 >= 0))

  defp fanout_concurrency(opts, form, env) do
    case Keyword.fetch(opts, :max_concurrency) do
      :error -> {:ok, nil}
      {:ok, n} when is_integer(n) and n > 0 -> {:ok, n}
      {:ok, _} -> {:error, Finding.at(env, form, "`max_concurrency` must be a positive integer")}
    end
  end

  defp fanout_bind(opts, form, env, binding_env) do
    case Keyword.fetch(opts, :bind) do
      :error ->
        {:ok, nil}

      {:ok, name} when is_atom(name) and not is_boolean(name) and not is_nil(name) ->
        cond do
          not String.match?(Atom.to_string(name), ~r/^[a-z_][a-zA-Z0-9_]*$/) ->
            {:error,
             Finding.at(env, form, "inadmissible binding name #{inspect(name)}",
               hint: "binding names must look like `:reviews` or `:results`"
             )}

          Map.has_key?(binding_env, name) ->
            {:error, Finding.at(env, form, "`fanout bind:` name #{inspect(name)} is already bound")}

          true ->
            {:ok, name}
        end

      {:ok, _other} ->
        {:error, Finding.at(env, form, "`fanout bind:` expects a literal binding atom")}
    end
  end

  defp fanout_on_zero(opts, form, env) do
    case Keyword.fetch(opts, :on_zero) do
      :error -> {:ok, :complete}
      {:ok, policy} when policy in [:complete, :fail] -> {:ok, policy}
      {:ok, _} -> {:error, Finding.at(env, form, "`on_zero` must be :complete or :fail")}
    end
  end

  defp fanout_body({:lanes, _meta, [lanes]}, width, address, form, env, binding_env) when is_list(lanes) do
    with :ok <- explicit_fanout_width(width, length(lanes), form, env),
         {:ok, lanes} <- explicit_fanout_lanes(lanes, address, form, env, binding_env) do
      {:ok, {:explicit, lanes}}
    end
  end

  defp fanout_body({:lanes, _meta, _args}, _width, _address, form, env, _binding_env) do
    {:error, Finding.at(env, form, "`lanes` requires a non-empty literal list of non-empty agent lanes")}
  end

  defp fanout_body(block, _width, address, form, env, binding_env) do
    case agent_lane(statements(block), address, env, binding_env, "fanout") do
      {:ok, []} ->
        {:error,
         Finding.at(env, form, "`fanout` requires at least one body step",
           hint: "the body is a lane of agent turns, e.g. fanout width: 2 do agent(\"...\") end"
         )}

      {:ok, agents} ->
        {:ok, {:repeat, agents}}

      {:error, _} = err ->
        err
    end
  end

  defp explicit_fanout_width(width, lane_count, _form, _env)
       when is_integer(width) and width == lane_count and lane_count > 0, do: :ok

  defp explicit_fanout_width(_width, 0, form, env) do
    {:error, Finding.at(env, form, "`lanes` requires at least one explicit lane")}
  end

  defp explicit_fanout_width(_width, _lane_count, form, env) do
    {:error,
     Finding.at(env, form, "`fanout width:` must equal the explicit lane count",
       hint: "explicit lanes require a literal integer width"
     )}
  end

  defp explicit_fanout_lanes(lanes, address, form, env, binding_env) do
    lanes
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn
      {[], _lane_index}, _acc ->
        {:halt, {:error, Finding.at(env, form, "explicit fanout lanes must not be empty")}}

      {lane, lane_index}, {:ok, acc} when is_list(lane) ->
        case explicit_fanout_lane(lane, address, lane_index, env, binding_env) do
          {:ok, agents} -> {:cont, {:ok, [agents | acc]}}
          {:error, _finding} = error -> {:halt, error}
        end

      {_lane, _lane_index}, _acc ->
        {:halt, {:error, Finding.at(env, form, "`lanes` entries must be non-empty literal lists of agents")}}
    end)
    |> case do
      {:ok, parsed} -> {:ok, Enum.reverse(parsed)}
      {:error, _finding} = error -> error
    end
  end

  defp explicit_fanout_lane(lane, address, lane_index, env, binding_env) do
    parse_agent_lane(
      lane,
      fn stage_index -> address ++ [lane_index, stage_index] end,
      env,
      binding_env,
      "fanout lane"
    )
  end

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

  defp legacy_fanout_lanes(block, width, address, form, env, binding_env) do
    case fanout_body(block, width, address, form, env, binding_env) do
      {:ok, {:repeat, _lane} = lanes} ->
        {:ok, lanes}

      {:ok, {:explicit, _lanes}} ->
        {:error, Finding.at(env, form, "`fan_out` does not accept explicit `lanes`")}

      {:error, _finding} = error ->
        error
    end
  end

  # Parse a list of statements that must each be an `agent` turn (shared by fanouts).
  # Reuses `node/4`, so closure/external-call and malformed-agent failures all
  # surface as located findings.
  defp agent_lane(stmts, address, env, binding_env, combinator) do
    parse_agent_lane(stmts, fn _stage_index -> address end, env, binding_env, combinator)
  end

  defp parse_agent_lane(stmts, address_for, env, binding_env, combinator) do
    stmts
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {stmt, stage_index}, {:ok, acc} ->
      case node(stmt, address_for.(stage_index), env, binding_env) do
        {:ok, %Agent{prompt: %Template{}}} ->
          {:halt, {:error, nested_template_prompt_finding(env, stmt, "#{combinator} body")}}

        {:ok, %Agent{} = agent} ->
          {:cont, {:ok, [agent | acc]}}

        {:ok, _other} ->
          {:halt,
           {:error,
            Finding.at(env, stmt, "`#{combinator}` body steps must be `agent` turns",
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

      %EmitResult{} ->
        :ok

      _other ->
        {:error,
         Finding.at(env, nil, "workflow must terminate with `return`, `emit`, or `emit_result`",
           hint: "end the workflow with `return literal`, `emit(~P\"...\")`, or `emit_result(:name)`"
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

  defp emit_template({:sigil_P, meta, [{:<<>>, _content_meta, [source]}, _mods]}, env) when is_binary(source) do
    Template.parse(source, %{env | line: Keyword.get(meta, :line, env.line)})
  end

  defp emit_template(_other, env) do
    {:error, Finding.at(env, nil, "`emit` expects a `~P` template", hint: ~s|emit(~P"Final: <%= @draft %>")|)}
  end

  defp prompt_template({:sigil_P, meta, [{:<<>>, _content_meta, [source]}, _mods]}, env) when is_binary(source) do
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
              hint: "bind it earlier with `let :#{assign} = agent(...)`, `synthesize(...)`, or `fanout bind: :#{assign}`"
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

  defp emit_result_ref(binding, binding_env, form, env) when is_atom(binding) do
    case Map.fetch(binding_env, binding) do
      {:ok, {:refine, _address} = ref} ->
        {:ok, ref}

      {:ok, ref} ->
        {:error,
         Finding.at(
           env,
           form,
           "`emit_result` requires a result-capable binding; #{inspect(binding)} is bound to #{binding_kind(ref)}"
         )}

      :error ->
        {:error, Finding.at(env, form, "`emit_result` references unknown binding #{inspect(binding)}")}
    end
  end

  defp emit_result_ref(_binding, _binding_env, form, env) do
    {:error, Finding.at(env, form, "`emit_result` expects a literal binding atom")}
  end

  defp binding_kind({:node, _address}), do: "agent"
  defp binding_kind({:refine, _address}), do: "refine"
  defp binding_kind({:map, _address}), do: "map"
  defp binding_kind({:fanout, _address, _scope}), do: "fanout"

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

  defp vocabulary, do: Enum.map_join(@combinators, ", ", &Atom.to_string/1)

  defp callee({{:., _, [module, fun]}, _, _}), do: "#{Macro.to_string(module)}.#{fun}"
end
