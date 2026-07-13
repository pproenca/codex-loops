defmodule Workflow.Run.Writer do
  @moduledoc """
  The single live writer for one run. It walks the inert tree, invokes the provider
  for agent nodes, drives dynamic loops, and commits ordered events to the journal.

  It owns a genuine serialised resource — the per-run write lease and the `seq`
  cursor — which is exactly what a process is for. The lease is the registry name:
  `start_link/1` registers `{:via, Registry, {Registry, run_id}}`, so a second
  writer for the same `run_id` fails with `{:already_started, pid}`. The registry
  monitors this process, releasing the lease on death.

  `start_link` returns as soon as the lease is held; the writer then idles until it
  receives `:begin`. Deferring the work to a message (rather than a
  `handle_continue`) lets the caller establish its `Process.monitor` before any
  effect runs, so a mid-turn crash is observed with its real exit reason rather
  than a `:noproc` race. On `:begin` the writer executes, reports its result to the
  a synchronous caller when present, and stops `:normal`. Unexpected crashes are still treated as bugs. For
  crashes, the async scheduler path also needs a terminal journal fact: the writer
  records `run_failed` before re-raising, so read models do not leave an ownerless
  run folded as forever running. A crash with an unmatched `agent_started` marker
  is recorded as `outcome_unknown` and that provider attempt is never redelivered.

  ## Execution context

  A small context threads through the walk: the `seq` cursor, the pending `return`
  value, the current loop `iteration` (0 at top level, the real per-iteration key
  component inside a loop), the enclosing loop's `seen_by` dedup field list, and the
  most recent agent result (`last_result`) that a `collect` reduces. It carries no
  authoritative state — every decision that matters is journaled and re-derivable by
  folding the log.
  """
  use GenServer, restart: :temporary

  alias Workflow.Accumulator
  alias Workflow.BoundList
  alias Workflow.BoundValue
  alias Workflow.Event
  alias Workflow.Event.Payload, as: P
  alias Workflow.Idempotency
  alias Workflow.IdempotencyKey
  alias Workflow.Journal
  alias Workflow.JSONPointer
  alias Workflow.JSONValue
  alias Workflow.Ledger
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
  alias Workflow.Node.Refine.ColdReadGate
  alias Workflow.Node.Refine.Gates
  alias Workflow.Node.Refine.HaltGate
  alias Workflow.Node.Refine.RepairGate
  alias Workflow.Node.Return
  alias Workflow.Node.Synthesize
  alias Workflow.Node.Until
  alias Workflow.Node.Verify
  alias Workflow.Predicate
  alias Workflow.Provider.Activity
  alias Workflow.Provider.Usage
  alias Workflow.PubSub
  alias Workflow.Refine.ColdRead
  alias Workflow.Refine.Gate
  alias Workflow.Refine.OpenFinding
  alias Workflow.Refine.Result, as: RefineResult
  alias Workflow.Refine.Review
  alias Workflow.Refine.Reviewer
  alias Workflow.Refine.ReviewerAdapter
  alias Workflow.Refine.ReviewerDecision
  alias Workflow.Refine.ReviewFinding
  alias Workflow.Refine.RoleFailure
  alias Workflow.Refine.RoundDecision
  alias Workflow.Refine.TerminalProjection
  alias Workflow.RenderText
  alias Workflow.Run.Options
  alias Workflow.Schema
  alias Workflow.Status
  alias Workflow.Status.Failure
  alias Workflow.Template
  alias Workflow.Tree

  @max_concurrency 8
  @max_fanout_width 64
  @fanout_timeout 31 * 60 * 1_000
  @default_refine_reviewer_timeout 30_000
  @provider_failure_kinds [:quota_exceeded, :model_limit, :timeout, :unavailable, :backend]

  def start_link({%Tree{}, %Options{run_id: run_id}, parent} = state) when is_pid(parent) or is_nil(parent) do
    GenServer.start_link(__MODULE__, state, name: via(run_id))
  end

  @doc "Release an idle writer to execute asynchronously."
  @spec start_execution(pid()) :: :ok
  def start_execution(pid) when is_pid(pid) do
    send(pid, :begin)
    :ok
  end

  @doc "Monitor an idle writer, release it, and wait for its terminal result."
  @spec run_to_completion(pid(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def run_to_completion(pid, run_id) when is_pid(pid) and is_binary(run_id) do
    # The monitor must exist before the writer runs a single effect. Since the
    # writer idles until start_execution/1 sends its private message, this preserves
    # the real mid-turn exit reason instead of racing into a synthetic :noproc DOWN.
    ref = Process.monitor(pid)
    :ok = start_execution(pid)
    await_completion(pid, run_id, ref)
  end

  @doc "The registry name that is this run's write lease."
  def via(run_id), do: {:via, Registry, {Workflow.Run.Registry, run_id}}

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_info(:begin, {_tree, %Options{run_id: run_id}, parent} = state) do
    result = execute_or_journal_crash(state)
    notify_parent(parent, run_id, result)
    {:stop, :normal, state}
  end

  defp await_completion(pid, run_id, ref) do
    receive do
      {:run_finished, ^run_id, result} ->
        Process.demonitor(ref, [:flush])
        result

      {:DOWN, ^ref, :process, ^pid, :normal} ->
        {:ok, run_id}

      {:DOWN, ^ref, :process, ^pid, reason} ->
        {:error, {:run_crashed, reason}}
    end
  end

  defp notify_parent(parent, run_id, result) when is_pid(parent) do
    send(parent, {:run_finished, run_id, result})
    :ok
  end

  defp notify_parent(nil, _run_id, _result), do: :ok

  defp execute_or_journal_crash({_tree, %Options{run_id: run_id}, _parent} = state) do
    execute(state)
  catch
    kind, reason ->
      stacktrace = __STACKTRACE__
      detail = crash_detail(kind, reason, stacktrace)
      maybe_journal_run_failed(run_id, detail)
      :erlang.raise(kind, reason, stacktrace)
  end

  defp maybe_journal_run_failed(run_id, detail) do
    events = Journal.fold(run_id)

    case Status.fold(events, run_id) do
      %Status{state: state} when state in [:completed, :failed] ->
        :ok

      %Status{} ->
        reason =
          case Idempotency.unsettled_attempt(events) do
            {:ok, key} -> outcome_unknown(key)
            :none -> detail
          end

        _event = persist(run_id, Event.run_failed(reason))
        :ok
    end
  end

  defp crash_detail(kind, reason, stacktrace) do
    %{
      "kind" => Atom.to_string(kind),
      "message" => Exception.format_banner(kind, reason),
      "stacktrace" => Exception.format_stacktrace(stacktrace)
    }
  end

  defp execute({%Tree{} = tree, %Options{run_id: run_id, provider: provider} = options, _parent}) do
    prior = Journal.fold(run_id)

    # Resume is a pure fold. If the journal already folds to a terminal state, that
    # state is reused verbatim: no fresh `run_started` is appended (which would
    # un-terminate the read model) and no settled turn is re-run.
    case Status.fold(prior, run_id) do
      %Status{state: :completed} ->
        {:ok, run_id}

      %Status{state: :failed, failure: failure} ->
        failed_run_result(failure)

      %Status{} ->
        case Idempotency.unsettled_attempt(prior) do
          {:ok, key} ->
            reason = outcome_unknown(key)
            _event = persist(run_id, Event.run_failed(reason))
            {:error, public_outcome_unknown(key)}

          :none ->
            run_tree(
              run_id,
              tree,
              provider,
              prior,
              options.budget,
              options.script_path,
              options.workspace_root
            )
        end
    end
  end

  defp failed_run_result(%Failure{reason: {:invalid_refine_input, address, reason}}),
    do: {:error, {:invalid_refine_input, address, reason}}

  defp failed_run_result(%Failure{reason: {:did_not_converge, address, reason}}),
    do: {:error, {:did_not_converge, address, reason}}

  defp failed_run_result(%Failure{reason: {:fanout_failed, address, iteration, reason}}),
    do: {:error, {:fanout_failed, address, iteration, reason}}

  defp failed_run_result(%Failure{reason: {:fanout_failed, address, reason}}),
    do: {:error, {:fanout_failed, address, nil, reason}}

  defp failed_run_result(%Failure{reason: {:loop_exhausted, address, iteration}}),
    do: {:error, {:loop_exhausted, address, iteration}}

  defp failed_run_result(%Failure{address: address, reason: {:provider_failure, kind, detail}}),
    do: {:error, {:provider_failure, address, kind, detail}}

  defp failed_run_result(%Failure{reason: {:run_crashed, detail}}), do: {:error, {:run_crashed, detail}}

  defp failed_run_result(%Failure{reason: {:outcome_unknown, %IdempotencyKey{} = key}}),
    do: {:error, public_outcome_unknown(key)}

  defp failed_run_result(%Failure{} = failure), do: {:error, {:malformed_output, failure.address, failure.reason}}

  defp outcome_unknown(%IdempotencyKey{} = key), do: {:outcome_unknown, key}

  defp public_outcome_unknown(%IdempotencyKey{} = key), do: {:outcome_unknown, IdempotencyKey.attempt_map(key)}

  defp failed_turn_result(%Agent{address: address}, reason), do: failed_turn_result(address, reason)

  defp failed_turn_result(address, {:provider_failure, kind, detail}), do: {:provider_failure, address, kind, detail}

  defp failed_turn_result(address, reason), do: {:malformed_output, address, reason}

  defp run_tree(run_id, tree, provider, prior, budget, script_path, workspace_root) do
    seq = Journal.last_seq(run_id) + 1

    # A fresh run gets its start marker (carrying the budget target, source path,
    # and workspace); a resume already carries one, so appending another would
    # falsely re-mark the folded run as `:running` and re-declare facts the journal
    # already owns.
    seq =
      if prior == [],
        do: commit(run_id, seq, Event.run_started(tree, budget, script_path, workspace_root)),
        else: seq

    ctx = %{seq: seq, return: nil, last_result: nil, iteration: 0, seen_by: [], loop_address: nil}

    case run_nodes(tree.nodes, run_id, provider, prior, ctx) do
      {:cont, ctx} ->
        _seq = commit(run_id, ctx.seq, Event.run_completed(ctx.return))
        {:ok, run_id}

      # A node failed closed: its terminal `agent_failed` is already journaled.
      {:halt, _ctx, reason} ->
        {:error, reason}
    end
  end

  # Walk a node list, threading the context and short-circuiting on the first halt.
  defp run_nodes(nodes, run_id, provider, prior, ctx) do
    Enum.reduce_while(nodes, {:cont, ctx}, fn node, {:cont, ctx} ->
      case run_node(node, run_id, provider, prior, ctx) do
        {:cont, ctx} -> {:cont, {:cont, ctx}}
        {:loop_stop, ctx, reason} -> {:halt, {:loop_stop, ctx, reason}}
        {:halt, ctx, reason} -> {:halt, {:halt, ctx, reason}}
      end
    end)
  end

  defp run_node(%Phase{} = node, run_id, _provider, prior, ctx),
    do: {:cont, %{ctx | seq: commit_marker(run_id, ctx.seq, prior, Event.phase_entered(node))}}

  defp run_node(%Log{} = node, run_id, _provider, prior, ctx),
    do: {:cont, %{ctx | seq: commit_marker(run_id, ctx.seq, prior, Event.log_emitted(node))}}

  defp run_node(%Return{} = node, _run_id, _provider, _prior, ctx), do: {:cont, %{ctx | return: node.value}}

  defp run_node(%Emit{} = node, run_id, _provider, _prior, ctx) do
    rendered =
      case RenderText.of(run_id, Template.to_parts(node.template, node.bindings)) do
        {:ok, value} ->
          value

        {:error, reason} ->
          raise ArgumentError, "unable to render terminal template: #{inspect(reason)}"
      end

    {:cont, %{ctx | return: rendered}}
  end

  defp run_node(%EmitResult{ref: {:refine, address}} = node, run_id, _provider, _prior, ctx) do
    case RefineResult.of(run_id, address) do
      {:ok, value} ->
        {:cont, %{ctx | return: value}}

      {:error, reason} ->
        raise ArgumentError,
              "unable to resolve structured result for #{inspect(node.binding)}: #{inspect(reason)}"
    end
  end

  # The sequential agent path commits each paid attempt *incrementally* — a rejection
  # lands in the journal before the next paid call runs — so a crash mid-retry
  # durably preserves the already-paid attempts and resume never re-pays them. The
  # committed/replayed result becomes `last_result`, which a following `collect` in
  # the same iteration harvests.
  defp run_node(%Agent{} = node, run_id, provider, prior, ctx) do
    iteration = ctx.iteration

    case resolve_agent_turn(node, prior, iteration) do
      # A settled turn is replayed from the journal, never re-run.
      {:committed, result, _usage} ->
        {:cont, %{ctx | last_result: result}}

      {:failed, reason} ->
        {:halt, ctx, failed_turn_result(node, reason)}

      {:exhausted, attempts, reason} ->
        seq = commit(run_id, ctx.seq, Event.agent_failed(node, iteration, attempts, reason))
        {:halt, %{ctx | seq: seq}, failed_turn_result(node, reason)}

      # Mid-flight resume: pick the retry loop back up at the first un-journaled
      # attempt rather than re-calling the provider for already-ledgered rejections.
      {:resume, next} ->
        commit_attempt(materialize_agent(node, run_id), run_id, provider, ctx, iteration, next)

      :none ->
        commit_attempt(materialize_agent(node, run_id), run_id, provider, ctx, iteration, 0)
    end
  end

  # A declared reduction. On resume, an iteration whose `accumulate` already landed
  # is replayed (skipped) so the accumulator is never double-counted. Otherwise the
  # iteration's harvest (`last_result`) is deduped against the journal-folded
  # accumulator using the enclosing loop's `seen_by`, and only the new items are
  # journaled — so folding the log rebuilds the accumulator exactly.
  defp run_node(%Collect{} = node, run_id, _provider, prior, ctx) do
    if journaled_accumulate?(prior, node.address, ctx.iteration) do
      {:cont, ctx}
    else
      harvest = List.wrap(ctx.last_result)
      current = Map.get(Accumulator.of(run_id), node.into, [])
      added = Accumulator.new_items(current, harvest, ctx.seen_by)

      event =
        Event.accumulate(node, ctx.iteration, ctx.seen_by, added, length(current) + length(added))

      {:cont, %{ctx | seq: commit(run_id, ctx.seq, event)}}
    end
  end

  defp run_node(%Until{} = node, run_id, _provider, prior, ctx) do
    run_until(node, run_id, prior, ctx)
  end

  # Generic bounded loop core.
  defp run_node(%Loop{} = node, run_id, provider, prior, ctx),
    do: loop(node, loop_seen_by(node.until), run_id, provider, prior, ctx, 0)

  # Barrier fan-out: bracket the concurrent region with started/completed markers,
  # run every branch concurrently under the cap, then commit each branch's journalled
  # events in branch order. Branches build events off-thread and never touch the
  # journal — only this single writer commits.
  defp run_node(%Parallel{} = node, run_id, provider, prior, ctx) do
    seq = commit_marker(run_id, ctx.seq, prior, Event.parallel_started(node))
    cap = node.max_concurrency || max(length(node.branches), 1)

    results =
      run_concurrently(node.branches, cap, fn branch ->
        to_lane_result(build_agent(branch, run_id, provider, prior, ctx.iteration))
      end)

    case commit_lanes(results, run_id, seq) do
      {:ok, seq} ->
        {:cont, %{ctx | seq: commit_marker(run_id, seq, prior, Event.parallel_completed(node))}}

      {:halt, seq, reason} ->
        {:halt, %{ctx | seq: seq}, reason}
    end
  end

  # Per-item fan-out: each lane runs its stages sequentially and independently; lanes
  # run concurrently under the cap with no cross-item barrier.
  defp run_node(%Pipeline{} = node, run_id, provider, prior, ctx) do
    seq = commit_marker(run_id, ctx.seq, prior, Event.pipeline_started(node))
    cap = node.max_concurrency || max(length(node.lanes), 1)

    results =
      run_concurrently(node.lanes, cap, fn lane ->
        run_lane(lane, run_id, provider, prior, ctx.iteration)
      end)

    case commit_lanes(results, run_id, seq) do
      {:ok, seq} ->
        {:cont, %{ctx | seq: commit_marker(run_id, seq, prior, Event.pipeline_completed(node))}}

      {:halt, seq, reason} ->
        {:halt, %{ctx | seq: seq}, reason}
    end
  end

  # Verification panel: run every voter concurrently under the (constant) panel
  # width, commit each vote in voter order, then settle survival by a pure fold of
  # the journaled verdicts against the threshold. A failed vote fails the panel.
  defp run_node(%Verify{} = node, run_id, provider, prior, ctx) do
    seq = commit_marker(run_id, ctx.seq, prior, Event.verify_started(node))
    cap = max(length(node.voters), 1)

    outcomes =
      run_concurrently(node.voters, cap, fn voter ->
        build_agent(voter, run_id, provider, prior, ctx.iteration)
      end)

    case commit_with_results(outcomes, run_id, seq) do
      {:ok, seq, votes} ->
        confirmations = Enum.count(votes, &confirmed?/1)
        total = length(votes)
        survived = survives?(confirmations, total, node.threshold)

        seq =
          commit_marker(
            run_id,
            seq,
            prior,
            Event.verify_settled(node, confirmations, total, survived)
          )

        result = %{survived: survived, confirmations: confirmations, total: total}
        {:cont, %{ctx | seq: seq, last_result: result}}

      {:halt, seq, reason} ->
        {:halt, %{ctx | seq: seq}, reason}
    end
  end

  defp run_node(%Refine{} = node, run_id, provider, prior, ctx) do
    node = materialize_refine_runtime(node)
    seq = commit_marker(run_id, ctx.seq, prior, Event.refine_started(node))
    node = replay_refine_started(node, prior)

    with {:ok, seq, artifact} <-
           run_refine_producer(node, run_id, provider, prior, %{ctx | seq: seq}),
         {:ok, seq, artifact} <-
           run_refine_loop(node, 0, artifact, run_id, provider, prior, seq) do
      {:cont, %{ctx | seq: seq, last_result: artifact}}
    else
      {:failed, seq, reason} -> {:halt, %{ctx | seq: seq}, reason}
    end
  end

  # Judge panel: score every candidate lane concurrently (each lane scores its
  # criteria in order), commit scores in candidate order, then pick a winner by a
  # pure fold of the journaled scores. A failed score fails the panel.
  defp run_node(%Judge{} = node, run_id, provider, prior, ctx) do
    seq = commit_marker(run_id, ctx.seq, prior, Event.judge_started(node))
    cap = max(length(node.scorers), 1)

    outcomes =
      run_concurrently(node.scorers, cap, fn lane ->
        score_lane(lane, run_id, provider, prior, ctx.iteration)
      end)

    case commit_with_results(outcomes, run_id, seq) do
      {:ok, seq, totals} ->
        scores = node.candidates |> Enum.zip(totals) |> Map.new()
        winner = pick_winner(node.pick, scores)
        seq = commit_marker(run_id, seq, prior, Event.judge_settled(node, scores, winner))
        {:cont, %{ctx | seq: seq, last_result: %{winner: winner, scores: scores}}}

      {:halt, seq, reason} ->
        {:halt, %{ctx | seq: seq}, reason}
    end
  end

  # Synthesis is one schemaless agent turn whose effective prompt
  # deterministically embeds the literal inputs; it reuses the ordinary agent path
  # verbatim, so it is journaled, keyed, and resumable with no special case.
  defp run_node(%Synthesize{} = node, run_id, provider, prior, ctx) do
    agent = %Agent{address: node.address, prompt: synthesis_prompt(node), schema: nil, retries: 0}
    run_node(agent, run_id, provider, prior, ctx)
  end

  # Generic fixed-width fanout: decide (and journal) the width once, repeat the
  # single lane across concrete branch addresses, then commit lane events in branch
  # order. Top-level fanouts carry marker iteration nil; loop-body fanouts use the
  # current loop iteration so their width/result binding is loop-local.
  defp run_node(%GenericFanout{} = node, run_id, provider, prior, ctx) do
    fanout_iteration = if ctx.loop_address, do: ctx.iteration
    lane_iteration = ctx.iteration
    {width, seq} = decide_fanout_width(node, run_id, prior, ctx.seq, fanout_iteration)

    if width == 0 and node.on_zero == :fail do
      seq = commit(run_id, seq, Event.fanout_failed(node, :zero_width, fanout_iteration))
      reason = {:fanout_failed, node.address, fanout_iteration, :zero_width}
      {:halt, %{ctx | seq: seq}, reason}
    else
      branches = materialize_fanout_branches(node, width)
      cap = node.max_concurrency || max(width, 1)

      results =
        run_concurrently(branches, cap, fn lane ->
          run_lane(lane, run_id, provider, prior, lane_iteration)
        end)

      case commit_lanes(results, run_id, seq) do
        {:ok, seq} ->
          seq = commit_fanout_completed(run_id, seq, prior, node, fanout_iteration)
          {:cont, %{ctx | seq: seq}}

        {:halt, seq, reason} ->
          {:halt, %{ctx | seq: seq}, reason}
      end
    end
  end

  # --- Verify / judge tally (pure folds over each panel's committed results) ---

  defp confirmed?(%{"verdict" => verdict}) when is_boolean(verdict), do: verdict

  defp survives?(confirmations, total, :majority), do: confirmations * 2 > total
  defp survives?(confirmations, total, :unanimous), do: confirmations == total
  defp survives?(confirmations, _total, :any), do: confirmations >= 1
  defp survives?(confirmations, _total, n) when is_integer(n), do: confirmations >= n

  defp replay_refine_started(%Refine{} = node, prior) do
    case journaled_refine_started(prior, node.address) do
      {:ok, payload} -> refine_from_started_payload(node, payload)
      :none -> node
    end
  end

  defp journaled_refine_started(prior, address) do
    case Enum.find_value(prior, fn
           %Event{payload: %P.RefineStarted{address: ^address} = payload} -> payload
           %Event{} -> nil
         end) do
      nil -> :none
      payload -> {:ok, payload}
    end
  end

  defp refine_from_started_payload(%Refine{} = node, %P.RefineStarted{} = payload) do
    %{
      node
      | input: payload.input,
        reviewers: payload.reviewers,
        reviser: payload.reviser,
        until: payload.until,
        max_rounds: payload.max_rounds,
        on_non_convergence: payload.on_non_convergence,
        max_concurrency: payload.max_concurrency,
        reviewer_timeout_ms: payload.reviewer_timeout_ms || refine_reviewer_timeout(),
        gates: payload.gates
    }
  end

  defp materialize_refine_runtime(%Refine{} = node) do
    %{node | reviewer_timeout_ms: node.reviewer_timeout_ms || refine_reviewer_timeout()}
  end

  defp run_refine_producer(%Refine{input: {:producer, producer}}, run_id, provider, prior, ctx) do
    case commit_role_agent(producer, run_id, provider, prior, ctx, 0) do
      {:cont, ctx, artifact} ->
        {:ok, ctx.seq, artifact}

      {:halt, ctx, reason} ->
        {:failed, ctx.seq, reason}
    end
  end

  defp run_refine_producer(%Refine{input: {:binding, name, ref}} = node, run_id, _provider, _prior, ctx) do
    case bound_artifact(run_id, ref) do
      {:ok, artifact} ->
        {:ok, ctx.seq, artifact}

      {:error, reason} ->
        input = %{kind: :binding, name: name, ref: ref}
        seq = commit(run_id, ctx.seq, Event.refine_input_invalid(node, input, reason))
        {:failed, seq, {:invalid_refine_input, node.address, reason}}
    end
  end

  defp bound_artifact(_run_id, {:map, _address}), do: {:error, :unsupported_map_binding}

  defp bound_artifact(run_id, ref) do
    case BoundValue.of(run_id, ref) do
      {:ok, value} -> normalize_bound_artifact(value)
      {:error, {:unbound, _ref}} -> {:error, :unbound_binding}
    end
  end

  defp normalize_bound_artifact(value) when is_binary(value) do
    if String.valid?(value), do: {:ok, value}, else: {:error, :artifact_invalid_utf8}
  end

  defp normalize_bound_artifact(%{"artifact" => artifact} = value) when map_size(value) == 1 and is_binary(artifact) do
    if String.valid?(artifact), do: {:ok, artifact}, else: {:error, :artifact_invalid_utf8}
  end

  defp normalize_bound_artifact(%{"artifact" => value}) when not is_binary(value), do: {:error, :artifact_not_binary}

  defp normalize_bound_artifact(value) when is_map(value), do: {:error, :artifact_object_unexpected_shape}

  defp normalize_bound_artifact(_value), do: {:error, :artifact_value_unsupported}

  defp run_refine_round(%Refine{} = node, round, artifact, run_id, provider, prior, seq) do
    seq =
      commit_round_marker(
        run_id,
        seq,
        prior,
        Event.refine_round_started(node, round, artifact)
      )

    case journaled_refine_decision(prior, node.address, round) do
      {:ok, decision} ->
        {:ok, seq, decision}

      :none ->
        run_refine_reviewers(node, round, artifact, run_id, provider, prior, seq)
    end
  end

  defp run_refine_reviewers(%Refine{} = node, round, artifact, run_id, provider, prior, seq) do
    cap = node.max_concurrency || max(length(node.reviewers), 1)
    timeout = node.reviewer_timeout_ms || refine_reviewer_timeout()

    outcomes =
      run_refine_reviewers_concurrently(
        node,
        node.reviewers,
        cap,
        timeout,
        round,
        fn %Reviewer{agent: agent, prompt: base_prompt} = reviewer ->
          agent = %{agent | prompt: reviewer_prompt(base_prompt, round, artifact)}

          build_reviewer_role_agent(
            node,
            %{reviewer | agent: agent},
            run_id,
            provider,
            prior,
            round
          )
        end
      )

    {:ok, seq, settlements} = commit_reviewer_lanes(outcomes, run_id, prior, seq)
    decision = refine_decision(node, round, artifact, settlements)
    seq = commit(run_id, seq, Event.refine_round_decision(node, round, decision))
    {:ok, seq, decision}
  end

  defp run_refine_loop(%Refine{} = node, round, artifact, run_id, provider, prior, seq) do
    with {:ok, seq, decision} <-
           run_refine_round(node, round, artifact, run_id, provider, prior, seq) do
      cond do
        decision.consensus ->
          finalize_refine(
            node,
            :completed,
            nil,
            true,
            round,
            artifact,
            %{decision | open_findings: []},
            run_id,
            provider,
            prior,
            seq
          )

        round == node.max_rounds - 1 and node.on_non_convergence == :accept_current ->
          finalize_refine(
            node,
            :completed,
            nil,
            false,
            round,
            artifact,
            decision,
            run_id,
            provider,
            prior,
            seq
          )

        round == node.max_rounds - 1 ->
          finalize_refine(
            node,
            :non_converged,
            :max_rounds,
            false,
            round,
            artifact,
            decision,
            run_id,
            provider,
            prior,
            seq
          )

        true ->
          case run_refine_reviser(
                 node,
                 round,
                 artifact,
                 decision.open_findings,
                 decision.role_failures,
                 run_id,
                 provider,
                 prior,
                 seq
               ) do
            {:ok, seq, revised_artifact} ->
              run_refine_loop(node, round + 1, revised_artifact, run_id, provider, prior, seq)

            {:failed, seq, reason} ->
              {:failed, seq, reason}
          end
      end
    end
  end

  defp finalize_refine(
         %Refine{} = node,
         base_terminal,
         base_reason,
         converged,
         round,
         artifact,
         decision,
         run_id,
         provider,
         prior,
         seq
       ) do
    projection = terminal_projection(converged, round, artifact, decision)

    with {:ok, seq, projection} <-
           maybe_run_cold_read_gate(node, projection, run_id, provider, seq),
         {:ok, seq, projection} <- maybe_run_repair_gate(node, projection, run_id, provider, seq),
         {:ok, seq, halt?} <- maybe_evaluate_halt_gate(node, projection, run_id, seq) do
      cond do
        halt? ->
          predicate = node.gates.halt.predicate
          reason = {:gate, predicate}

          seq =
            commit_refine_non_converged(
              run_id,
              seq,
              prior,
              Event.refine_non_converged(node, projection, reason)
            )

          {:failed, seq, {:did_not_converge, node.address, reason}}

        base_terminal == :non_converged ->
          seq =
            commit_refine_non_converged(
              run_id,
              seq,
              prior,
              Event.refine_non_converged(node, projection, base_reason)
            )

          {:failed, seq, {:did_not_converge, node.address, base_reason}}

        true ->
          seq =
            commit_refine_completed(
              run_id,
              seq,
              prior,
              Event.refine_completed(node, projection)
            )

          {:ok, seq, projection.artifact}
      end
    end
  end

  defp terminal_projection(converged, round, artifact, decision) do
    TerminalProjection.new(converged, round, artifact, decision)
  end

  defp maybe_run_cold_read_gate(%Refine{gates: %Gates{} = gates} = node, projection, run_id, provider, seq) do
    case gates.cold_read do
      nil ->
        {:ok, seq, projection}

      %ColdReadGate{} = gate ->
        case evaluate_gate(node, :cold_read, gate.predicate, projection, run_id, seq) do
          {:ok, seq, true} -> run_or_replay_cold_read(node, gate.reviewer, projection, run_id, provider, seq)
          {:ok, seq, false} -> {:ok, seq, projection}
        end
    end
  end

  defp maybe_run_repair_gate(%Refine{gates: %Gates{} = gates} = node, projection, run_id, provider, seq) do
    case gates.repair do
      nil ->
        {:ok, seq, projection}

      %RepairGate{} = gate ->
        case evaluate_gate(node, :repair, gate.predicate, projection, run_id, seq) do
          {:ok, seq, true} -> run_or_replay_repair(node, gate.agent, projection, run_id, provider, seq)
          {:ok, seq, false} -> {:ok, seq, projection}
        end
    end
  end

  defp maybe_evaluate_halt_gate(%Refine{gates: %Gates{} = gates} = node, projection, run_id, seq) do
    case gates.halt do
      nil ->
        {:ok, seq, false}

      %HaltGate{predicate: predicate} ->
        evaluate_gate(node, :halt, predicate, projection, run_id, seq)
    end
  end

  defp evaluate_gate(%Refine{} = node, gate, predicate, projection, run_id, seq) do
    events = Journal.fold(run_id)

    case journaled_refine_gate(events, node.address, gate) do
      {:ok, result} ->
        {:ok, seq, result}

      :none ->
        json = RefineResult.public(projection, events, run_id, node.address)
        %{"rawRefs" => %{"journal" => input_refs}} = json
        result = Gate.evaluate(predicate, json)

        event =
          Event.refine_gate_evaluated(node, gate, predicate,
            result: result,
            input_round: projection.final_round,
            input_refs: input_refs
          )

        {:ok, commit(run_id, seq, event), result}
    end
  end

  defp journaled_refine_gate(events, address, gate) do
    case Enum.find_value(events, fn
           %Event{payload: %P.RefineGateEvaluated{address: ^address, gate: ^gate, result: result}} ->
             {:found, result}

           %Event{} ->
             nil
         end) do
      nil -> :none
      {:found, result} -> {:ok, result}
    end
  end

  defp run_or_replay_cold_read(
         %Refine{} = node,
         %Reviewer{agent: %Agent{} = agent} = reviewer,
         projection,
         run_id,
         provider,
         seq
       ) do
    agent = %{agent | prompt: cold_read_prompt(agent.prompt, projection, run_id, node.address)}
    events = Journal.fold(run_id)

    case gate_role_state(events, node.address, :cold_read, agent, 0) do
      {:committed, review} ->
        {:ok, seq, cold_read_completed_projection(projection, reviewer, Review.from_payload(review))}

      {:failed, failure} ->
        {:ok, seq, cold_read_failed_projection(projection, failure)}

      {:exhausted, attempts, reason} ->
        {seq, failure} =
          commit_exhausted_gate_role_failure(
            node,
            :cold_read,
            reviewer,
            agent,
            run_id,
            seq,
            attempts,
            reason
          )

        {:ok, seq, cold_read_failed_projection(projection, failure)}

      {:resume, attempt} ->
        node
        |> run_cold_read_role_attempt(
          reviewer,
          agent,
          run_id,
          provider,
          seq,
          attempt
        )
        |> cold_read_attempt_result(projection, reviewer)
    end
  end

  defp run_or_replay_repair(%Refine{} = node, %Agent{} = agent, projection, run_id, provider, seq) do
    agent = %{agent | prompt: repair_prompt(agent.prompt, projection, run_id, node.address)}
    events = Journal.fold(run_id)

    case gate_role_state(events, node.address, :repair, agent, 0) do
      {:committed, artifact} ->
        {:ok, seq, repair_completed_projection(projection, artifact)}

      {:failed, failure} ->
        {:ok, seq, append_role_failure(projection, failure)}

      {:exhausted, attempts, reason} ->
        {seq, failure} =
          commit_exhausted_gate_role_failure(
            node,
            :repair,
            nil,
            agent,
            run_id,
            seq,
            attempts,
            reason
          )

        {:ok, seq, append_role_failure(projection, failure)}

      {:resume, attempt} ->
        node
        |> commit_repair_attempt(agent, run_id, provider, %{seq: seq}, 0, attempt)
        |> repair_attempt_result(projection)
    end
  end

  defp gate_role_state(events, address, role, %Agent{} = agent, iteration) do
    case journaled_gate_role_failure(events, address, role, agent.address) do
      {:ok, failure} ->
        {:failed, failure}

      :none ->
        case resolve_agent_turn(agent, events, iteration) do
          {:committed, result, _usage} -> {:committed, result}
          {:failed, reason} -> {:failed, gate_role_failure(address, role, agent, 1, reason, [])}
          {:exhausted, attempts, reason} -> {:exhausted, attempts, reason}
          {:resume, attempt} -> {:resume, attempt}
          :none -> {:resume, 0}
        end
    end
  end

  defp journaled_gate_role_failure(events, address, role, role_address) do
    case Enum.find_value(events, fn
           %Event{
             payload:
               %P.RefineRoleFailed{
                 address: ^address,
                 role: ^role,
                 round: nil,
                 role_address: ^role_address
               } = payload
           } ->
             payload

           %Event{} ->
             nil
         end) do
      nil -> :none
      payload -> {:ok, P.RefineRoleFailed.role_failure(payload)}
    end
  end

  defp run_cold_read_role_attempt(
         %Refine{} = refine,
         %Reviewer{} = reviewer,
         %Agent{} = agent,
         run_id,
         provider,
         seq,
         attempt
       ) do
    timeout = refine.reviewer_timeout_ms || refine_reviewer_timeout()

    task =
      Task.Supervisor.async_nolink(Workflow.TaskSupervisor, fn ->
        build_cold_read_attempt(
          refine,
          reviewer,
          agent,
          run_id,
          provider,
          0,
          attempt,
          []
        )
      end)

    case Task.yield(task, timeout) do
      {:ok, {:ok, events, review}} ->
        {:ok, commit_all(run_id, seq, events), review}

      {:ok, {:role_failed, events, failure}} ->
        seq = commit_all(run_id, seq, events)

        seq =
          commit_refine_role_failed(
            run_id,
            seq,
            Journal.fold(run_id),
            Event.refine_role_failed(failure)
          )

        {:failed, seq, failure}

      nil ->
        Task.shutdown(task, :brutal_kill)

        failure =
          gate_role_failure(
            refine.address,
            :cold_read,
            reviewer,
            agent,
            max(attempt + 1, 1),
            {:cold_read_timeout, timeout},
            detail: timeout
          )

        seq =
          commit_refine_role_failed(
            run_id,
            seq,
            Journal.fold(run_id),
            Event.refine_role_failed(failure)
          )

        {:failed, seq, failure}

      {:exit, {:codex_turn_outcome_unknown, detail}} ->
        exit({:codex_turn_outcome_unknown, detail})

      {:exit, {%_{} = exception, stacktrace}} when is_list(stacktrace) ->
        reraise exception, stacktrace

      {:exit, reason} ->
        failure =
          gate_role_failure(
            refine.address,
            :cold_read,
            reviewer,
            agent,
            max(attempt + 1, 1),
            {:cold_read_crashed, reason},
            detail: reason
          )

        seq =
          commit_refine_role_failed(
            run_id,
            seq,
            Journal.fold(run_id),
            Event.refine_role_failed(failure)
          )

        {:failed, seq, failure}
    end
  end

  defp build_cold_read_attempt(
         %Refine{} = refine,
         %Reviewer{} = reviewer,
         %Agent{} = agent,
         run_id,
         provider,
         iteration,
         attempt,
         acc
       ) do
    key = key(run_id, agent.address, iteration, attempt)
    {activity_sink, finalize_activity} = activity_tracker(run_id, agent, iteration, attempt)

    case call_provider(provider, agent.prompt, agent.schema, key, activity_sink) do
      {:ok, output, usage, activity} ->
        activity = finalize_activity.(activity)

        case ReviewerAdapter.normalize(reviewer.adapter, output) do
          {:ok, %Review{} = review} ->
            committed = Event.agent_committed(agent, iteration, key, review, usage, activity)
            {:ok, Enum.reverse([committed | acc]), review}

          {:error, reason} ->
            rejected =
              Event.agent_attempt_rejected(
                agent,
                iteration,
                attempt,
                output,
                reason,
                usage,
                activity
              )

            if attempt < agent.retries do
              build_cold_read_attempt(
                refine,
                reviewer,
                agent,
                run_id,
                provider,
                iteration,
                attempt + 1,
                [rejected | acc]
              )
            else
              failure =
                gate_role_failure(
                  refine.address,
                  :cold_read,
                  reviewer,
                  agent,
                  attempt + 1,
                  gate_role_malformed_reason(:cold_read, reason),
                  detail: reason
                )

              {:role_failed, Enum.reverse([rejected | acc]), failure}
            end
        end

      {:provider_failure, kind, detail, usage, activity} ->
        activity = finalize_activity.(activity)

        failure =
          gate_role_failure(
            refine.address,
            :cold_read,
            reviewer,
            agent,
            attempt + 1,
            gate_role_provider_reason(:cold_read, kind, detail),
            detail: detail,
            usage: usage,
            activity: activity
          )

        {:role_failed, Enum.reverse(acc), failure}
    end
  end

  defp commit_exhausted_gate_role_failure(
         %Refine{} = refine,
         role,
         role_owner,
         %Agent{} = agent,
         run_id,
         seq,
         attempts,
         reason
       ) do
    failure =
      gate_role_failure(
        refine.address,
        role,
        role_owner,
        agent,
        attempts,
        gate_role_malformed_reason(role, reason),
        detail: reason
      )

    event = Event.refine_role_failed(failure)
    seq = commit_refine_role_failed(run_id, seq, Journal.fold(run_id), event)
    {seq, failure}
  end

  defp commit_repair_attempt(%Refine{} = refine, %Agent{} = agent, run_id, provider, ctx, iteration, attempt) do
    key = key(run_id, agent.address, iteration, attempt)
    {activity_sink, finalize_activity} = activity_tracker(run_id, agent, iteration, attempt)

    case call_provider(provider, agent.prompt, agent.schema, key, activity_sink) do
      {:ok, output, usage, activity} ->
        activity = finalize_activity.(activity)

        case normalize_artifact(output) do
          {:ok, artifact} ->
            seq =
              commit(
                run_id,
                ctx.seq,
                Event.agent_committed(agent, iteration, key, artifact, usage, activity)
              )

            {:ok, seq, artifact}

          {:error, reason} ->
            seq =
              commit(
                run_id,
                ctx.seq,
                Event.agent_attempt_rejected(
                  agent,
                  iteration,
                  attempt,
                  output,
                  reason,
                  usage,
                  activity
                )
              )

            if attempt < agent.retries do
              commit_repair_attempt(
                refine,
                agent,
                run_id,
                provider,
                %{ctx | seq: seq},
                iteration,
                attempt + 1
              )
            else
              failure =
                gate_role_failure(
                  refine.address,
                  :repair,
                  nil,
                  agent,
                  attempt + 1,
                  gate_role_malformed_reason(:repair, reason),
                  detail: reason
                )

              event = Event.refine_role_failed(failure)
              seq = commit_refine_role_failed(run_id, seq, Journal.fold(run_id), event)
              {:failed, seq, failure}
            end
        end

      {:provider_failure, kind, detail, usage, activity} ->
        activity = finalize_activity.(activity)

        failure =
          gate_role_failure(
            refine.address,
            :repair,
            nil,
            agent,
            attempt + 1,
            gate_role_provider_reason(:repair, kind, detail),
            detail: detail,
            usage: usage,
            activity: activity
          )

        event = Event.refine_role_failed(failure)
        seq = commit_refine_role_failed(run_id, ctx.seq, Journal.fold(run_id), event)
        {:failed, seq, failure}
    end
  end

  defp cold_read_attempt_result({:ok, seq, review}, projection, reviewer),
    do: {:ok, seq, cold_read_completed_projection(projection, reviewer, review)}

  defp cold_read_attempt_result({:failed, seq, failure}, projection, _reviewer),
    do: {:ok, seq, cold_read_failed_projection(projection, failure)}

  defp repair_attempt_result({:ok, seq, artifact}, projection),
    do: {:ok, seq, repair_completed_projection(projection, artifact)}

  defp repair_attempt_result({:failed, seq, failure}, projection),
    do: {:ok, seq, append_role_failure(projection, failure)}

  defp cold_read_completed_projection(projection, reviewer, %Review{} = review) do
    open_findings = review_open_findings(reviewer, review)
    reviewer_decision = review_decision(reviewer, review)

    %{
      projection
      | cold_read:
          ColdRead.completed(
            open_findings,
            reviewer_decision,
            review.report_snippets
          )
    }
  end

  defp cold_read_failed_projection(projection, failure) do
    projection
    |> append_role_failure(failure)
    |> Map.put(:cold_read, ColdRead.failed(failure))
  end

  defp repair_completed_projection(projection, artifact) do
    cold_read =
      case projection.cold_read do
        %ColdRead{} = cold_read -> ColdRead.repaired(cold_read)
        nil -> nil
      end

    %{projection | artifact: artifact, cold_read: cold_read}
  end

  defp append_role_failure(projection, %RoleFailure{} = failure) do
    role_failures = projection.role_failures ++ [failure]

    %{
      projection
      | role_failures: role_failures,
        failed_reviewers: failed_reviewers(role_failures)
    }
  end

  defp review_decision(%Reviewer{index: index, name: name, adapter: adapter}, %Review{} = review) do
    %ReviewerDecision{
      reviewer: name,
      reviewer_index: index,
      adapter: adapter,
      outcome: reviewer_outcome(review)
    }
  end

  defp reviewer_outcome(%Review{approved: false}), do: :rejected

  defp reviewer_outcome(%Review{approved: true, findings: findings}) do
    if Enum.any?(findings, & &1.blocking), do: :approved_with_findings, else: :clear
  end

  defp review_open_findings(%Reviewer{index: index, name: name}, %Review{approved: approved, findings: findings}) do
    blocking =
      findings
      |> Enum.filter(& &1.blocking)
      |> Enum.uniq_by(& &1.id)
      |> Enum.sort_by(& &1.id, :asc)

    cond do
      blocking != [] ->
        Enum.map(blocking, &open_finding(name, index, &1))

      not approved ->
        [
          %OpenFinding{
            reviewer: name,
            reviewer_index: index,
            id: "__codex_loops_no_blocking_finding__",
            issue: "Reviewer did not approve but returned no blocking finding.",
            fix: "Revise the artifact to address this reviewer, or return approved: true with no blocking findings."
          }
        ]

      true ->
        []
    end
  end

  defp gate_role_failure(address, role, %Agent{} = agent, attempts, reason, opts) do
    gate_role_failure(address, role, nil, agent, attempts, reason, opts)
  end

  defp gate_role_failure(address, role, role_owner, %Agent{} = agent, attempts, reason, opts)
       when is_nil(role_owner) or is_struct(role_owner, Reviewer) do
    {reviewer, reviewer_index} = role_owner_identity(role_owner)

    %RoleFailure{
      address: address,
      role: role,
      role_address: agent.address,
      round: nil,
      reviewer: reviewer,
      reviewer_index: reviewer_index,
      attempts: attempts,
      reason: reason,
      detail: Keyword.get(opts, :detail),
      usage: Keyword.get(opts, :usage),
      activity: Keyword.get(opts, :activity, [])
    }
  end

  defp role_owner_identity(nil), do: {nil, nil}

  defp role_owner_identity(%Reviewer{name: name, index: index}), do: {name, index}

  defp gate_role_malformed_reason(:repair, reason), do: {:repair_failed, reason}
  defp gate_role_malformed_reason(_role, reason), do: {:malformed_output, reason}

  defp gate_role_provider_reason(:repair, kind, detail), do: {:repair_failed, {:provider_failure, kind, detail}}

  defp gate_role_provider_reason(_role, kind, detail), do: {:provider_failure, kind, detail}

  defp cold_read_prompt(base, projection, _run_id, _address) do
    RenderText.render!([], [
      {:text, base},
      {:text, "\n\n--- CODEX LOOPS REFINE COLD READ INPUT ---\n"},
      {:text, "artifact-bytes: #{byte_size(projection.artifact)}\n"},
      {:text, "artifact:\n"},
      {:text, projection.artifact},
      {:text, "\nopen-finding-count: #{length(projection.open_findings)}\n"},
      {:text, serialize_findings(projection.open_findings)},
      {:text, "role-failure-count: #{length(projection.role_failures)}\n"},
      {:text, serialize_role_failures(projection.role_failures)},
      {:text, "--- END CODEX LOOPS REFINE COLD READ INPUT ---"}
    ])
  end

  defp repair_prompt(base, projection, _run_id, _address) do
    reviser_prompt(
      base,
      projection.final_round,
      projection.artifact,
      projection.open_findings ++ cold_read_open_findings(projection.cold_read),
      projection.role_failures
    )
  end

  defp cold_read_open_findings(%{state: :completed, open_findings: open_findings}), do: open_findings

  defp cold_read_open_findings(_cold_read), do: []

  defp run_refine_reviser(%Refine{} = node, round, artifact, open_findings, role_failures, run_id, provider, prior, seq) do
    reviser = %{
      node.reviser
      | prompt: reviser_prompt(node.reviser.prompt, round, artifact, open_findings, role_failures)
    }

    case commit_role_agent(
           reviser,
           run_id,
           provider,
           prior,
           %{seq: seq},
           round
         ) do
      {:cont, ctx, revised_artifact} ->
        {:ok, ctx.seq, revised_artifact}

      {:halt, ctx, reason} ->
        {:failed, ctx.seq, reason}
    end
  end

  defp refine_decision(%Refine{} = node, _round, artifact, settlements) do
    decisions =
      node.reviewers
      |> Enum.zip(settlements)
      |> Enum.map(fn
        {%Reviewer{} = reviewer, {:completed, review}} ->
          review_decision(reviewer, review)

        {%Reviewer{index: index, name: name, adapter: adapter}, {:failed, _failure}} ->
          %ReviewerDecision{
            reviewer: name,
            reviewer_index: index,
            adapter: adapter,
            outcome: :failed
          }
      end)

    open_findings =
      node.reviewers
      |> Enum.zip(settlements)
      |> Enum.flat_map(fn
        {%Reviewer{} = reviewer, {:completed, review}} ->
          review_open_findings(reviewer, review)

        {_reviewer, {:failed, _failure}} ->
          []
      end)

    role_failures = role_failures(settlements)
    approval_count = Enum.count(decisions, &ReviewerDecision.clear?/1)

    %RoundDecision{
      consensus: approval_count == length(decisions) and role_failures == [],
      approval_count: approval_count,
      total: length(decisions),
      reviewer_decisions: decisions,
      artifact: artifact,
      open_findings: open_findings,
      role_failures: role_failures,
      failed_reviewers: failed_reviewers(role_failures),
      report_snippets: report_snippets(settlements)
    }
  end

  defp role_failures(settlements) do
    Enum.flat_map(settlements, fn
      {:failed, failure} -> [failure]
      {:completed, _review} -> []
    end)
  end

  defp failed_reviewers(role_failures) do
    role_failures
    |> Enum.map(& &1.reviewer)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp reviewer_role_failure(
         %Refine{} = refine,
         %Reviewer{index: index, name: name, agent: %Agent{} = agent},
         round,
         attempts,
         reason,
         opts
       ) do
    %RoleFailure{
      address: refine.address,
      role: :reviewer,
      role_address: agent.address,
      round: round,
      reviewer: name,
      reviewer_index: index,
      attempts: attempts,
      reason: reason,
      detail: Keyword.get(opts, :detail),
      usage: Keyword.get(opts, :usage),
      activity: Keyword.get(opts, :activity, [])
    }
  end

  defp report_snippets(settlements) do
    Enum.flat_map(settlements, fn
      {:completed, %Review{report_snippets: snippets}} -> snippets
      {:failed, _failure} -> []
    end)
  end

  defp open_finding(name, index, %ReviewFinding{} = finding) do
    %OpenFinding{
      reviewer: name,
      reviewer_index: index,
      id: finding.id,
      issue: finding.issue,
      fix: finding.fix
    }
  end

  defp reviewer_prompt(base, round, artifact) do
    RenderText.render!([], [
      {:text, base},
      {:text, "\n\n--- CODEX LOOPS REFINE REVIEW INPUT ---\n"},
      {:text, "round: #{round}\n"},
      {:text, "artifact-bytes: #{byte_size(artifact)}\n"},
      {:text, "artifact:\n"},
      {:text, artifact},
      {:text, "\n--- END CODEX LOOPS REFINE REVIEW INPUT ---"}
    ])
  end

  defp reviser_prompt(base, round, artifact, open_findings, role_failures) do
    RenderText.render!([], [
      {:text, base},
      {:text, "\n\n--- CODEX LOOPS REFINE REVISION INPUT ---\n"},
      {:text, "round: #{round}\n"},
      {:text, "current-artifact-bytes: #{byte_size(artifact)}\n"},
      {:text, "current-artifact:\n"},
      {:text, artifact},
      {:text, "\nblocking-finding-count: #{length(open_findings)}\n"},
      {:text, serialize_findings(open_findings)},
      {:text, "reviewer-role-failure-count: #{length(role_failures)}\n"},
      {:text, serialize_role_failures(role_failures)},
      {:text, "--- END CODEX LOOPS REFINE REVISION INPUT ---"}
    ])
  end

  defp serialize_findings(open_findings) do
    open_findings
    |> Enum.with_index(1)
    |> Enum.map_join(fn {finding, index} ->
      [
        "finding #{index}:\n",
        "reviewer: #{finding.reviewer}\n",
        "reviewer-index: #{finding.reviewer_index}\n",
        "id-bytes: #{byte_size(finding.id)}\n",
        "id:\n",
        finding.id,
        "\n",
        "issue-bytes: #{byte_size(finding.issue)}\n",
        "issue:\n",
        finding.issue,
        "\n",
        "fix-bytes: #{byte_size(finding.fix)}\n",
        "fix:\n",
        finding.fix,
        "\n"
      ]
    end)
  end

  defp serialize_role_failures(role_failures) do
    role_failures
    |> Enum.with_index(1)
    |> Enum.map_join(fn {failure, index} ->
      [
        "role-failure #{index}:\n",
        "reviewer: #{failure.reviewer}\n",
        "reviewer-index: #{failure.reviewer_index}\n",
        "reason:\n",
        inspect(failure.reason),
        "\n",
        "detail:\n",
        inspect(failure.detail),
        "\n"
      ]
    end)
  end

  defp commit_round_marker(run_id, seq, prior, %Event{payload: payload} = event) do
    if journaled_round_marker?(prior, payload) do
      seq
    else
      commit(run_id, seq, event)
    end
  end

  defp journaled_round_marker?(prior, %P.RefineRoundStarted{address: address, round: round}) do
    Enum.any?(prior, fn
      %Event{payload: %P.RefineRoundStarted{address: ^address, round: ^round}} -> true
      %Event{} -> false
    end)
  end

  defp journaled_round_marker?(prior, %P.RefineRoundDecision{address: address, round: round}) do
    Enum.any?(prior, fn
      %Event{payload: %P.RefineRoundDecision{address: ^address, round: ^round}} -> true
      %Event{} -> false
    end)
  end

  defp commit_refine_completed(run_id, seq, prior, %Event{payload: %P.RefineCompleted{address: address}} = event) do
    if Enum.any?(prior, fn
         %Event{payload: %P.RefineCompleted{address: ^address}} -> true
         %Event{} -> false
       end) do
      seq
    else
      commit(run_id, seq, event)
    end
  end

  defp commit_refine_non_converged(run_id, seq, prior, %Event{payload: %P.RefineNonConverged{address: address}} = event) do
    if Enum.any?(prior, fn
         %Event{payload: %P.RefineNonConverged{address: ^address}} -> true
         %Event{} -> false
       end) do
      seq
    else
      commit(run_id, seq, event)
    end
  end

  defp commit_refine_role_failed(
         run_id,
         seq,
         prior,
         %Event{payload: %P.RefineRoleFailed{address: address, role: role, round: round, role_address: role_address}} =
           event
       ) do
    if Enum.any?(prior, fn
         %Event{
           payload: %P.RefineRoleFailed{
             address: ^address,
             role: ^role,
             round: ^round,
             role_address: ^role_address
           }
         } ->
           true

         %Event{} ->
           false
       end) do
      seq
    else
      commit(run_id, seq, event)
    end
  end

  defp journaled_refine_decision(prior, address, round) do
    case Enum.find_value(prior, fn
           %Event{payload: %P.RefineRoundDecision{address: ^address, round: ^round} = payload} -> payload
           %Event{} -> nil
         end) do
      nil -> :none
      payload -> {:ok, replayed_refine_decision(payload)}
    end
  end

  defp replayed_refine_decision(%P.RefineRoundDecision{} = payload), do: P.RefineRoundDecision.decision(payload)

  defp journaled_refine_role_failure(prior, address, round, %Reviewer{agent: %Agent{} = agent}) do
    agent_address = agent.address

    case Enum.find_value(prior, fn
           %Event{
             payload:
               %P.RefineRoleFailed{
                 address: ^address,
                 role: :reviewer,
                 round: ^round,
                 role_address: ^agent_address
               } = payload
           } ->
             payload

           %Event{} ->
             nil
         end) do
      nil -> :none
      payload -> {:ok, P.RefineRoleFailed.role_failure(payload)}
    end
  end

  # A candidate's total is the sum of its per-criterion scores.
  defp score_lane(lane, run_id, provider, prior, iteration) do
    lane
    |> Enum.reduce_while({:ok, [], 0}, fn agent, {:ok, events, total} ->
      case build_agent(agent, run_id, provider, prior, iteration) do
        {:ok, evs, %{"score" => score}} -> {:cont, {:ok, events ++ evs, total + score}}
        {:failed, evs, reason} -> {:halt, {:failed, events ++ evs, reason}}
      end
    end)
    |> case do
      {:ok, events, total} -> {:ok, events, total}
      {:failed, _events, _reason} = failed -> failed
    end
  end

  defp pick_winner(:max_score, scores), do: scores |> Enum.max_by(&elem(&1, 1)) |> elem(0)
  defp pick_winner(:min_score, scores), do: scores |> Enum.min_by(&elem(&1, 1)) |> elem(0)

  # Commit each lane's events in order (like `commit_lanes`) while threading the
  # per-lane result out for the panel to fold. On a failed lane the events still
  # commit; the first failure reason halts the panel.
  defp commit_with_results(outcomes, run_id, seq) do
    {results, {seq, failure}} =
      Enum.flat_map_reduce(outcomes, {seq, nil}, fn
        {:ok, events, result}, {seq, failure} ->
          {[result], {commit_all(run_id, seq, events), failure}}

        {:failed, events, reason}, {seq, failure} ->
          {[], {commit_all(run_id, seq, events), failure || reason}}
      end)

    case failure do
      nil -> {:ok, seq, results}
      reason -> {:halt, seq, reason}
    end
  end

  defp commit_reviewer_lanes(outcomes, run_id, prior, seq) do
    {settlements, seq} =
      Enum.map_reduce(outcomes, seq, fn
        {:ok, events, review}, seq ->
          {{:completed, review}, commit_all(run_id, seq, events)}

        {:role_failed, events, failure}, seq ->
          seq = commit_all(run_id, seq, events)
          event = Event.refine_role_failed(failure)
          seq = commit_refine_role_failed(run_id, seq, prior, event)
          {{:failed, failure}, seq}
      end)

    {:ok, seq, settlements}
  end

  defp synthesis_prompt(%Synthesize{inputs: inputs, prompt: prompt}),
    do: RenderText.render!([], [{:text, prompt}, {:text, "\n\nInputs: "}, {:literal, inputs}])

  # --- Generic fanout width (a journaled runtime decision) ---

  defp decide_fanout_width(%GenericFanout{} = node, run_id, prior, seq, iteration) do
    case journaled_fanout_width(prior, node.address, iteration) do
      {:ok, width} ->
        {width, seq}

      :none ->
        width = compute_fanout_width(node.width, run_id)
        {width, commit(run_id, seq, Event.fanout_started(node, width, iteration))}
    end
  end

  defp compute_fanout_width(width, _run_id) when is_integer(width), do: cap_width(width, nil)
  defp compute_fanout_width(%BudgetSlices{} = width, run_id), do: compute_width(width, run_id)

  defp compute_fanout_width(%PathCount{ref: ref, pointer: pointer, max: max}, run_id) do
    events = Journal.fold(run_id)

    case resolve_binding_ref(events, ref) do
      {:ok, value} ->
        value
        |> JSONPointer.resolve(pointer)
        |> JSONValue.count_resolution()
        |> min(max)
        |> cap_width(nil)

      {:error, reason} ->
        raise ArgumentError, "unable to resolve path_count fanout width: #{inspect(reason)}"
    end
  end

  defp journaled_fanout_width(prior, address, iteration) do
    case Enum.find_value(prior, fn
           %Event{payload: %P.FanoutStarted{address: ^address, iteration: ^iteration, width: width}} ->
             {:found, width}

           %Event{payload: %P.LegacyFanOutStarted{address: ^address, width: width}}
           when is_nil(iteration) ->
             {:found, width}

           %Event{} ->
             nil
         end) do
      nil -> :none
      {:found, width} -> {:ok, width}
    end
  end

  defp commit_fanout_completed(run_id, seq, prior, %GenericFanout{} = node, iteration) do
    if journaled_fanout_completed?(prior, node.address, iteration) do
      seq
    else
      commit(run_id, seq, Event.fanout_completed(node, iteration))
    end
  end

  defp journaled_fanout_completed?(prior, address, iteration) do
    Enum.any?(prior, fn
      %Event{payload: %P.FanoutCompleted{address: ^address, iteration: ^iteration}} ->
        true

      %Event{payload: %P.LegacyFanOutCompleted{address: ^address}} when is_nil(iteration) ->
        true

      %Event{} ->
        false
    end)
  end

  defp materialize_fanout_branches(%GenericFanout{lanes: {:repeat, lane}} = node, width) do
    for i <- 0..(width - 1)//1, do: rebase_body(lane, node.address ++ [i])
  end

  defp materialize_fanout_branches(%GenericFanout{lanes: {:explicit, lanes}}, _width), do: lanes

  defp compute_width(%BudgetSlices{per: per, max: cap}, run_id) do
    case Ledger.remaining(Ledger.of(run_id)) do
      :infinity ->
        raise ArgumentError, "budget_slices requires a bounded run (no budget target set)"

      remaining ->
        remaining
        |> max(0)
        |> div(per)
        |> cap_width(cap)
    end
  end

  defp cap_width(width, nil), do: min(width, @max_fanout_width)
  defp cap_width(width, cap), do: min(width, min(cap, @max_fanout_width))

  # Re-address a body template lane onto a concrete branch: stage `s` -> `branch ++ [s]`.
  defp rebase_body(body, branch_address) do
    Enum.with_index(body, fn %Agent{} = agent, s -> %{agent | address: branch_address ++ [s]} end)
  end

  # --- Dynamic loop driver ---

  # One tail-recursive pass per prospective iteration. The continue/stop *decision*
  # is journaled and, on resume, replayed from the log rather than recomputed — a
  # fresh recompute would read a ledger/accumulator fold that reflects the whole run,
  # not the historical decision point. A `:continue` runs the body under this
  # iteration's key (its committed turns replay on resume); a `:stop` closes the loop
  # bracket.
  defp loop(node, seen_by, run_id, provider, prior, ctx, iteration) do
    {control, ctx} = decide(node, run_id, prior, ctx, iteration)

    case control.decision do
      {:stop, reason} ->
        {:cont,
         %{
           ctx
           | seq:
               commit_marker(
                 run_id,
                 ctx.seq,
                 prior,
                 Event.loop_completed(node, iteration, exhausted: false, reason: reason)
               )
         }}

      {:exhausted, :fail} ->
        seq = commit(run_id, ctx.seq, Event.loop_exhausted(node, iteration, :max_iterations))
        {:halt, %{ctx | seq: seq}, {:loop_exhausted, node.address, iteration}}

      {:exhausted, action} when action in [:stop, :accept_current] ->
        {:cont,
         %{
           ctx
           | seq:
               commit_marker(
                 run_id,
                 ctx.seq,
                 prior,
                 Event.loop_completed(node, iteration,
                   exhausted: true,
                   reason: :max_iterations
                 )
               )
         }}

      :continue ->
        seq = iteration_marker(run_id, ctx.seq, prior, node, iteration)

        body_ctx = %{
          ctx
          | seq: seq,
            iteration: iteration,
            loop_address: node.address,
            seen_by: seen_by,
            last_result: nil
        }

        case run_nodes(node.body, run_id, provider, prior, body_ctx) do
          {:cont, body_ctx} ->
            loop(
              node,
              seen_by,
              run_id,
              provider,
              prior,
              %{ctx | seq: body_ctx.seq},
              iteration + 1
            )

          {:loop_stop, body_ctx, reason} ->
            {:cont,
             %{
               ctx
               | seq:
                   commit_marker(
                     run_id,
                     body_ctx.seq,
                     prior,
                     Event.loop_completed(node, iteration + 1,
                       exhausted: false,
                       reason: reason
                     )
                   )
             }}

          {:halt, body_ctx, reason} ->
            {:halt, %{ctx | seq: body_ctx.seq}, reason}
        end
    end
  end

  # Replay a journaled decision verbatim; only compute (and journal) a fresh one when
  # this iteration has never been decided.
  defp decide(node, run_id, prior, ctx, iteration) do
    case journaled_decision(prior, node.address, iteration, nil) do
      {:ok, payload} ->
        {replayed_control(payload), ctx}

      :none ->
        control = fresh_decision(node, run_id, iteration)

        {control,
         %{
           ctx
           | seq:
               commit(
                 run_id,
                 ctx.seq,
                 Event.loop_decision(node, iteration, control.decision,
                   predicate_result: control.predicate_result,
                   exhausted: control.exhausted,
                   source_address: nil
                 )
               )
         }}
    end
  end

  defp run_until(%Until{} = node, run_id, prior, %{loop_address: loop_address} = ctx)
       when is_list(loop_address) and is_integer(ctx.iteration) do
    case journaled_decision(prior, loop_address, ctx.iteration, node.address) do
      {:ok, payload} ->
        case replayed_control(payload).decision do
          {:stop, reason} -> {:loop_stop, ctx, reason}
          :continue -> {:cont, ctx}
        end

      :none ->
        result =
          Predicate.evaluate(
            node.predicate,
            predicate_context(run_id, loop_address, ctx.iteration, node.predicate)
          )

        decision = if result, do: {:stop, :until}, else: :continue

        seq =
          commit(
            run_id,
            ctx.seq,
            Event.loop_decision(loop_address, ctx.iteration, decision,
              predicate_result: result,
              exhausted: false,
              source_address: node.address
            )
          )

        ctx = %{ctx | seq: seq}

        if result, do: {:loop_stop, ctx, :until}, else: {:cont, ctx}
    end
  end

  defp fresh_decision(%Loop{} = node, run_id, iteration) do
    cond do
      iteration >= node.max_iterations ->
        control({:exhausted, node.on_exhausted}, nil, true)

      node.until ->
        result =
          Predicate.evaluate(
            node.until,
            predicate_context(run_id, node.address, iteration, node.until)
          )

        if result,
          do: control({:stop, :until}, true, false),
          else: control(:continue, false, false)

      true ->
        control(:continue, false, false)
    end
  end

  defp control(decision, predicate_result, exhausted) do
    %{decision: decision, predicate_result: predicate_result, exhausted: exhausted}
  end

  defp replayed_control(%P.LoopDecision{} = payload) do
    %{
      decision: payload.decision,
      predicate_result: payload.predicate_result,
      exhausted: payload.exhausted
    }
  end

  defp predicate_context(run_id, loop_address, iteration, predicate) do
    %Predicate.Context{
      accumulators: Accumulator.of(run_id),
      remaining: Ledger.remaining(Ledger.of(run_id)),
      dry_streak: dry_streak(run_id, loop_address, iteration),
      bindings: predicate_bindings(run_id, predicate, iteration)
    }
  end

  defp loop_seen_by(nil), do: []

  defp loop_seen_by(predicate) do
    case Predicate.dry_seen_by(predicate) do
      {:ok, seen_by} -> seen_by
      {:error, :conflicting_seen_by} -> raise ArgumentError, "conflicting dry seen_by lists"
    end
  end

  defp predicate_bindings(_run_id, nil, _iteration), do: %{}

  defp predicate_bindings(run_id, predicate, iteration) do
    events = Journal.fold(run_id)

    predicate
    |> Predicate.binding_refs()
    |> Enum.uniq()
    |> Enum.reduce(%{}, fn ref, acc ->
      case resolve_binding_ref(events, ref, iteration) do
        {:ok, value} -> Map.put(acc, ref, value)
        {:error, _reason} -> acc
      end
    end)
  end

  defp resolve_binding_ref(events, ref, iteration \\ nil)

  defp resolve_binding_ref(events, {:node, _address} = ref, _iteration), do: BoundValue.fold(events, ref)

  defp resolve_binding_ref(events, {:refine, _address} = ref, _iteration), do: BoundValue.fold(events, ref)

  defp resolve_binding_ref(events, {:map, _address} = ref, _iteration), do: BoundList.fold(events, ref)

  defp resolve_binding_ref(events, {:fanout, _address, :global} = ref, _iteration), do: BoundList.fold(events, ref)

  defp resolve_binding_ref(events, {:fanout, _address, {:loop_local, _loop_address}} = ref, iteration)
       when is_integer(iteration), do: BoundList.fold(events, ref, iteration)

  defp resolve_binding_ref(_events, {:fanout, _address, {:loop_local, _loop_address}} = ref, _iteration),
    do: {:error, {:unbound, ref}}

  # Consecutive most-recent iterations (ending at `iteration - 1`) whose `collect`s
  # added nothing — derived purely from the journal, never from re-run agent output.
  defp dry_streak(run_id, loop_address, iteration) do
    added_by_round =
      run_id
      |> Journal.fold()
      |> Enum.flat_map(fn
        %Event{payload: %P.Accumulate{address: address} = payload} ->
          if List.starts_with?(address, loop_address), do: [payload], else: []

        %Event{} ->
          []
      end)
      |> Enum.group_by(& &1.iteration, &length(&1.added))
      |> Map.new(fn {round, counts} -> {round, Enum.sum(counts)} end)

    count_trailing_dry(added_by_round, iteration - 1, 0)
  end

  defp count_trailing_dry(_added_by_round, round, streak) when round < 0, do: streak

  defp count_trailing_dry(added_by_round, round, streak) do
    case Map.get(added_by_round, round, 0) do
      0 -> count_trailing_dry(added_by_round, round - 1, streak + 1)
      _ -> streak
    end
  end

  # --- Bounded, ordered concurrent fan-out (shared by parallel/pipeline) ---

  defp run_concurrently(inputs, cap, fun) do
    Workflow.TaskSupervisor
    |> Task.Supervisor.async_stream_nolink(inputs, fun,
      max_concurrency: concurrency_cap(cap),
      ordered: true,
      timeout: @fanout_timeout,
      on_timeout: :kill_task
    )
    |> Enum.map(fn
      {:ok, result} -> result
      {:exit, :timeout} -> raise "concurrent workflow branch exceeded #{@fanout_timeout} ms"
      {:exit, {%_{} = exception, stacktrace}} when is_list(stacktrace) -> reraise exception, stacktrace
      {:exit, reason} -> exit({:concurrent_workflow_branch_crashed, reason})
    end)
  end

  defp run_refine_reviewers_concurrently(%Refine{} = refine, reviewers, cap, timeout, iteration, fun) do
    Workflow.TaskSupervisor
    |> Task.Supervisor.async_stream_nolink(
      reviewers,
      fn reviewer -> safe_refine_reviewer(reviewer, iteration, fun) end,
      max_concurrency: concurrency_cap(cap),
      ordered: true,
      timeout: timeout,
      on_timeout: :kill_task
    )
    |> Enum.zip(reviewers)
    |> Enum.map(fn
      {{:ok, result}, _reviewer} ->
        result

      {{:exit, :timeout}, reviewer} ->
        failed_refine_reviewer(refine, reviewer, iteration, {:reviewer_timeout, timeout}, detail: timeout)

      {{:exit, {:codex_turn_outcome_unknown, detail}}, _reviewer} ->
        exit({:codex_turn_outcome_unknown, detail})

      {{:exit, {%_{} = exception, stacktrace}}, _reviewer} when is_list(stacktrace) ->
        reraise exception, stacktrace

      {{:exit, reason}, reviewer} ->
        failed_refine_reviewer(refine, reviewer, iteration, {:reviewer_crashed, reason}, detail: reason)
    end)
  end

  defp concurrency_cap(requested), do: requested |> max(1) |> min(@max_concurrency)

  defp safe_refine_reviewer(reviewer, _iteration, fun) do
    fun.(reviewer)
  end

  defp failed_refine_reviewer(%Refine{} = refine, %Reviewer{agent: %Agent{}} = reviewer, iteration, reason, opts) do
    {:role_failed, [], reviewer_role_failure(refine, reviewer, iteration, 1, reason, opts)}
  end

  defp refine_reviewer_timeout do
    case Application.get_env(
           :codex_loops,
           :refine_reviewer_timeout,
           @default_refine_reviewer_timeout
         ) do
      timeout when is_integer(timeout) and timeout > 0 -> timeout
      _invalid -> @default_refine_reviewer_timeout
    end
  end

  defp run_lane(lane, run_id, provider, prior, iteration) do
    Enum.reduce_while(lane, {:ok, []}, fn agent, {:ok, acc} ->
      case build_agent(agent, run_id, provider, prior, iteration) do
        {:ok, events, _result} -> {:cont, {:ok, acc ++ events}}
        {:failed, events, reason} -> {:halt, {:failed, acc ++ events, reason}}
      end
    end)
  end

  defp to_lane_result({:ok, events, _result}), do: {:ok, events}
  defp to_lane_result({:failed, events, reason}), do: {:failed, events, reason}

  defp commit_lanes(results, run_id, seq) do
    {seq, failure} =
      Enum.reduce(results, {seq, nil}, fn
        {:ok, events}, {seq, failure} ->
          {commit_all(run_id, seq, events), failure}

        {:failed, events, reason}, {seq, failure} ->
          {commit_all(run_id, seq, events), failure || reason}
      end)

    case failure do
      nil -> {:ok, seq}
      reason -> {:halt, seq, reason}
    end
  end

  # --- Sequential agent turn: commits each paid attempt as it happens ---

  defp resolve_agent_turn(%Agent{} = node, prior, iteration) do
    case Idempotency.resolve(prior, node.address, iteration) do
      {:resume, next} when next > node.retries ->
        {:exhausted, next, latest_rejected_reason(prior, node.address, iteration)}

      other ->
        other
    end
  end

  defp latest_rejected_reason(prior, address, iteration) do
    prior
    |> Enum.filter(fn
      %Event{payload: %P.AgentAttemptRejected{address: ^address, iteration: ^iteration}} ->
        true

      _event ->
        false
    end)
    |> case do
      [] ->
        :retry_exhausted

      rejected ->
        rejected
        |> Enum.max_by(& &1.payload.attempt)
        |> then(& &1.payload.reason)
    end
  end

  defp commit_attempt(%Agent{schema: nil} = node, run_id, provider, ctx, iteration, attempt) do
    key = key(run_id, node.address, iteration, attempt)
    {activity_sink, finalize_activity} = activity_tracker(run_id, node, iteration, attempt)

    case call_provider(provider, node.prompt, nil, key, activity_sink) do
      {:ok, result, usage, activity} ->
        activity = finalize_activity.(activity)

        seq =
          commit(
            run_id,
            ctx.seq,
            Event.agent_committed(node, iteration, key, result, usage, activity)
          )

        {:cont, %{ctx | seq: seq, last_result: result}}

      {:provider_failure, kind, detail, usage, activity} ->
        activity = finalize_activity.(activity)
        reason = {:provider_failure, kind, detail}

        seq =
          commit(
            run_id,
            ctx.seq,
            Event.agent_failed(node, iteration, attempt + 1, reason, usage, activity)
          )

        {:halt, %{ctx | seq: seq}, failed_turn_result(node, reason)}
    end
  end

  defp commit_attempt(%Agent{} = node, run_id, provider, ctx, iteration, attempt) do
    key = key(run_id, node.address, iteration, attempt)
    {activity_sink, finalize_activity} = activity_tracker(run_id, node, iteration, attempt)

    case call_provider(provider, node.prompt, node.schema, key, activity_sink) do
      {:ok, output, usage, activity} ->
        activity = finalize_activity.(activity)

        case Schema.validate(node.schema, output) do
          {:ok, validated} ->
            seq =
              commit(
                run_id,
                ctx.seq,
                Event.agent_committed(node, iteration, key, validated, usage, activity)
              )

            {:cont, %{ctx | seq: seq, last_result: validated}}

          {:error, reason} ->
            seq =
              commit(
                run_id,
                ctx.seq,
                Event.agent_attempt_rejected(
                  node,
                  iteration,
                  attempt,
                  output,
                  reason,
                  usage,
                  activity
                )
              )

            if attempt < node.retries do
              commit_attempt(node, run_id, provider, %{ctx | seq: seq}, iteration, attempt + 1)
            else
              seq = commit(run_id, seq, Event.agent_failed(node, iteration, attempt + 1, reason))
              {:halt, %{ctx | seq: seq}, failed_turn_result(node, reason)}
            end
        end

      {:provider_failure, kind, detail, usage, activity} ->
        activity = finalize_activity.(activity)
        reason = {:provider_failure, kind, detail}

        seq =
          commit(
            run_id,
            ctx.seq,
            Event.agent_failed(node, iteration, attempt + 1, reason, usage, activity)
          )

        {:halt, %{ctx | seq: seq}, failed_turn_result(node, reason)}
    end
  end

  # --- Concurrent agent turn: builds events off-thread for the writer to commit ---

  defp build_agent(%Agent{} = node, run_id, provider, prior, iteration) do
    case resolve_agent_turn(node, prior, iteration) do
      {:committed, result, _usage} ->
        {:ok, [], result}

      {:failed, reason} ->
        {:failed, [], failed_turn_result(node, reason)}

      {:exhausted, attempts, reason} ->
        {:failed, [Event.agent_failed(node, iteration, attempts, reason)], failed_turn_result(node, reason)}

      {:resume, next} ->
        build_attempt(materialize_agent(node, run_id), run_id, provider, iteration, next, [])

      :none ->
        build_attempt(materialize_agent(node, run_id), run_id, provider, iteration, 0, [])
    end
  end

  defp build_reviewer_role_agent(
         %Refine{} = refine,
         %Reviewer{agent: %Agent{} = node} = reviewer,
         run_id,
         provider,
         prior,
         iteration
       ) do
    case journaled_refine_role_failure(prior, refine.address, iteration, reviewer) do
      {:ok, failure} ->
        {:role_failed, [], failure}

      :none ->
        case resolve_agent_turn(node, prior, iteration) do
          {:committed, result, _usage} ->
            {:ok, [], Review.from_payload(result)}

          {:failed, reason} ->
            {:role_failed, [],
             reviewer_role_failure(refine, reviewer, iteration, 1, {:malformed_output, reason}, detail: reason)}

          {:exhausted, attempts, reason} ->
            {:role_failed, [],
             reviewer_role_failure(
               refine,
               reviewer,
               iteration,
               attempts,
               {:malformed_output, reason},
               detail: reason
             )}

          {:resume, next} ->
            build_reviewer_role_attempt(
              refine,
              reviewer,
              run_id,
              provider,
              iteration,
              next,
              []
            )

          :none ->
            build_reviewer_role_attempt(
              refine,
              reviewer,
              run_id,
              provider,
              iteration,
              0,
              []
            )
        end
    end
  end

  defp commit_role_agent(%Agent{} = node, run_id, provider, prior, ctx, iteration) do
    case resolve_agent_turn(node, prior, iteration) do
      {:committed, artifact, _usage} when is_binary(artifact) ->
        {:cont, ctx, artifact}

      {:failed, reason} ->
        {:halt, ctx, failed_turn_result(node, reason)}

      {:exhausted, attempts, reason} ->
        seq = commit(run_id, ctx.seq, Event.agent_failed(node, iteration, attempts, reason))
        {:halt, %{ctx | seq: seq}, failed_turn_result(node, reason)}

      {:resume, next} ->
        commit_role_attempt(
          materialize_agent(node, run_id),
          run_id,
          provider,
          ctx,
          iteration,
          next
        )

      :none ->
        commit_role_attempt(
          materialize_agent(node, run_id),
          run_id,
          provider,
          ctx,
          iteration,
          0
        )
    end
  end

  defp commit_role_attempt(%Agent{} = node, run_id, provider, ctx, iteration, attempt) do
    key = key(run_id, node.address, iteration, attempt)
    {activity_sink, finalize_activity} = activity_tracker(run_id, node, iteration, attempt)

    case call_provider(provider, node.prompt, node.schema, key, activity_sink) do
      {:ok, output, usage, activity} ->
        activity = finalize_activity.(activity)

        case normalize_artifact(output) do
          {:ok, artifact} ->
            seq =
              commit(
                run_id,
                ctx.seq,
                Event.agent_committed(node, iteration, key, artifact, usage, activity)
              )

            {:cont, %{ctx | seq: seq}, artifact}

          {:error, reason} ->
            seq =
              commit(
                run_id,
                ctx.seq,
                Event.agent_attempt_rejected(
                  node,
                  iteration,
                  attempt,
                  output,
                  reason,
                  usage,
                  activity
                )
              )

            if attempt < node.retries do
              commit_role_attempt(
                node,
                run_id,
                provider,
                %{ctx | seq: seq},
                iteration,
                attempt + 1
              )
            else
              seq = commit(run_id, seq, Event.agent_failed(node, iteration, attempt + 1, reason))
              {:halt, %{ctx | seq: seq}, failed_turn_result(node, reason)}
            end
        end

      {:provider_failure, kind, detail, usage, activity} ->
        activity = finalize_activity.(activity)
        reason = {:provider_failure, kind, detail}

        seq =
          commit(
            run_id,
            ctx.seq,
            Event.agent_failed(node, iteration, attempt + 1, reason, usage, activity)
          )

        {:halt, %{ctx | seq: seq}, failed_turn_result(node, reason)}
    end
  end

  defp build_reviewer_role_attempt(
         %Refine{} = refine,
         %Reviewer{agent: %Agent{} = node} = reviewer,
         run_id,
         provider,
         iteration,
         attempt,
         acc
       ) do
    key = key(run_id, node.address, iteration, attempt)
    {activity_sink, finalize_activity} = activity_tracker(run_id, node, iteration, attempt)

    case call_provider(provider, node.prompt, node.schema, key, activity_sink) do
      {:ok, output, usage, activity} ->
        activity = finalize_activity.(activity)

        case ReviewerAdapter.normalize(reviewer.adapter, output) do
          {:ok, %Review{} = review} ->
            committed = Event.agent_committed(node, iteration, key, review, usage, activity)
            {:ok, Enum.reverse([committed | acc]), review}

          {:error, reason} ->
            rejected =
              Event.agent_attempt_rejected(
                node,
                iteration,
                attempt,
                output,
                reason,
                usage,
                activity
              )

            if attempt < node.retries do
              build_reviewer_role_attempt(
                refine,
                reviewer,
                run_id,
                provider,
                iteration,
                attempt + 1,
                [rejected | acc]
              )
            else
              failure =
                reviewer_role_failure(
                  refine,
                  reviewer,
                  iteration,
                  attempt + 1,
                  {:malformed_output, reason},
                  detail: reason
                )

              {:role_failed, Enum.reverse([rejected | acc]), failure}
            end
        end

      {:provider_failure, kind, detail, usage, activity} ->
        activity = finalize_activity.(activity)
        reason = {:provider_failure, kind, detail}

        failure =
          reviewer_role_failure(refine, reviewer, iteration, attempt + 1, reason,
            detail: detail,
            usage: usage,
            activity: activity
          )

        {:role_failed, Enum.reverse(acc), failure}
    end
  end

  defp normalize_artifact(%{"artifact" => artifact} = output) when map_size(output) == 1 and is_binary(artifact) do
    if String.valid?(artifact), do: {:ok, artifact}, else: {:error, :artifact_invalid_utf8}
  end

  defp normalize_artifact(%{"artifact" => value}) when not is_binary(value), do: {:error, :artifact_not_binary}

  defp normalize_artifact(_output), do: {:error, :artifact_object_unexpected_shape}

  defp build_attempt(%Agent{schema: nil} = node, run_id, provider, iteration, attempt, _acc) do
    key = key(run_id, node.address, iteration, attempt)
    {activity_sink, finalize_activity} = activity_tracker(run_id, node, iteration, attempt)

    case call_provider(provider, node.prompt, nil, key, activity_sink) do
      {:ok, result, usage, activity} ->
        activity = finalize_activity.(activity)
        {:ok, [Event.agent_committed(node, iteration, key, result, usage, activity)], result}

      {:provider_failure, kind, detail, usage, activity} ->
        activity = finalize_activity.(activity)
        reason = {:provider_failure, kind, detail}
        failed = Event.agent_failed(node, iteration, attempt + 1, reason, usage, activity)

        {:failed, [failed], failed_turn_result(node, reason)}
    end
  end

  defp build_attempt(%Agent{} = node, run_id, provider, iteration, attempt, acc) do
    key = key(run_id, node.address, iteration, attempt)
    {activity_sink, finalize_activity} = activity_tracker(run_id, node, iteration, attempt)

    case call_provider(provider, node.prompt, node.schema, key, activity_sink) do
      {:ok, output, usage, activity} ->
        activity = finalize_activity.(activity)

        case Schema.validate(node.schema, output) do
          {:ok, validated} ->
            committed = Event.agent_committed(node, iteration, key, validated, usage, activity)
            {:ok, Enum.reverse([committed | acc]), validated}

          {:error, reason} ->
            rejected =
              Event.agent_attempt_rejected(
                node,
                iteration,
                attempt,
                output,
                reason,
                usage,
                activity
              )

            if attempt < node.retries do
              build_attempt(node, run_id, provider, iteration, attempt + 1, [rejected | acc])
            else
              failed = Event.agent_failed(node, iteration, attempt + 1, reason)

              {:failed, Enum.reverse([failed, rejected | acc]), failed_turn_result(node, reason)}
            end
        end

      {:provider_failure, kind, detail, usage, activity} ->
        activity = finalize_activity.(activity)
        reason = {:provider_failure, kind, detail}
        failed = Event.agent_failed(node, iteration, attempt + 1, reason, usage, activity)

        {:failed, Enum.reverse([failed | acc]), failed_turn_result(node, reason)}
    end
  end

  defp key(run_id, address, iteration, attempt),
    do: %IdempotencyKey{run_id: run_id, node_path: address, iteration: iteration, attempt: attempt}

  defp commit_all(run_id, seq, events), do: Enum.reduce(events, seq, fn event, seq -> commit(run_id, seq, event) end)

  defp activity_tracker(run_id, %Agent{} = node, iteration, attempt) do
    _started = persist(run_id, Event.agent_started(node, iteration, key(run_id, node.address, iteration, attempt)))

    sink = fn raw_entry ->
      entry = Activity.normalize!(raw_entry)
      event = Event.agent_activity(node, iteration, attempt, Activity.without_index(entry))
      persisted = persist(run_id, event)
      persisted.payload.activity_index
    end

    finalize = fn activity ->
      activity
      |> List.wrap()
      |> Enum.map(fn
        %Activity{activity_index: index} = entry when is_integer(index) ->
          entry

        %Activity{} = entry ->
          Activity.with_index(entry, sink.(entry))
      end)
    end

    {sink, finalize}
  end

  defp call_provider({module, opts}, prompt, schema, key, activity_sink),
    do: normalize_provider_result(module.run_agent(prompt, schema, key, Keyword.put(opts, :activity_sink, activity_sink)))

  defp normalize_provider_result({:ok, result, usage}), do: {:ok, result, normalize_usage!(usage, :success), []}

  defp normalize_provider_result({:ok, result, usage, activity}),
    do: {:ok, result, normalize_usage!(usage, :success), normalize_activity!(activity)}

  defp normalize_provider_result({:error, {:provider_failure, kind, detail, usage, activity}}) do
    if kind not in @provider_failure_kinds do
      raise ArgumentError, "invalid provider failure kind: #{inspect(kind)}"
    end

    if !JSONValue.durable_detail?(detail) do
      raise ArgumentError, "invalid provider failure detail: #{inspect(detail)}"
    end

    {:provider_failure, kind, detail, normalize_usage!(usage, :provider_failure), normalize_activity!(activity)}
  end

  defp normalize_provider_result(other), do: raise(ArgumentError, "malformed provider result: #{inspect(other)}")

  defp normalize_usage!(nil, :success), do: %Usage{}
  defp normalize_usage!(nil, :provider_failure), do: nil

  defp normalize_usage!(%Usage{} = usage, _context) do
    if non_negative_usage?(usage) do
      usage
    else
      raise ArgumentError, "invalid provider usage: #{inspect(usage)}"
    end
  end

  defp normalize_usage!(%{"input_tokens" => input, "output_tokens" => output, "total_tokens" => total}, _context)
       when is_integer(input) and is_integer(output) and is_integer(total) do
    normalized = %Usage{
      input_tokens: input,
      output_tokens: output,
      total_tokens: total
    }

    normalize_usage!(normalized, :map)
  end

  defp normalize_usage!(other, _context), do: raise(ArgumentError, "invalid provider usage: #{inspect(other)}")

  defp normalize_activity!(activity) when is_list(activity) do
    Enum.map(activity, &Activity.normalize!/1)
  end

  defp normalize_activity!(other), do: raise(ArgumentError, "invalid provider activity: #{inspect(other)}")

  defp non_negative_usage?(%Usage{input_tokens: input, output_tokens: output, total_tokens: total}) do
    Enum.all?([input, output, total], &(is_integer(&1) and &1 >= 0))
  end

  defp materialize_agent(%Agent{} = node, run_id) do
    schema = node.schema && Schema.new(node.schema)
    %{node | prompt: materialize_prompt(node, run_id), schema: schema}
  end

  defp materialize_prompt(%Agent{prompt: prompt}, _run_id) when is_binary(prompt), do: prompt

  defp materialize_prompt(%Agent{prompt: %Template{} = template, bindings: bindings}, run_id) do
    case RenderText.of(run_id, Template.to_parts(template, bindings)) do
      {:ok, prompt} ->
        prompt

      {:error, reason} ->
        raise ArgumentError, "unable to render agent template prompt: #{inspect(reason)}"
    end
  end

  # --- Journal idempotency for positional (non-paid) events ---

  # A structural marker (phase/log entry, fan-out or loop bracket) is a *positional*
  # event: its identity is `(payload variant, address)`. On a fresh walk it is
  # committed; on resume the tree is re-walked from the top, so any marker already
  # journaled at this address is reused verbatim rather than re-emitted.
  defp commit_marker(run_id, seq, prior, %Event{payload: payload} = event) do
    if journaled_marker?(prior, payload), do: seq, else: commit(run_id, seq, event)
  end

  defp journaled_marker?(prior, payload) do
    Enum.any?(prior, fn
      %Event{payload: prior_payload} -> same_marker?(prior_payload, payload)
    end)
  end

  defp same_marker?(%P.PhaseEntered{address: address}, %P.PhaseEntered{address: address}), do: true
  defp same_marker?(%P.LogEmitted{address: address}, %P.LogEmitted{address: address}), do: true
  defp same_marker?(%P.ParallelStarted{address: address}, %P.ParallelStarted{address: address}), do: true
  defp same_marker?(%P.ParallelCompleted{address: address}, %P.ParallelCompleted{address: address}), do: true
  defp same_marker?(%P.PipelineStarted{address: address}, %P.PipelineStarted{address: address}), do: true
  defp same_marker?(%P.PipelineCompleted{address: address}, %P.PipelineCompleted{address: address}), do: true
  defp same_marker?(%P.VerifyStarted{address: address}, %P.VerifyStarted{address: address}), do: true
  defp same_marker?(%P.VerifySettled{address: address}, %P.VerifySettled{address: address}), do: true
  defp same_marker?(%P.RefineStarted{address: address}, %P.RefineStarted{address: address}), do: true
  defp same_marker?(%P.JudgeStarted{address: address}, %P.JudgeStarted{address: address}), do: true
  defp same_marker?(%P.JudgeSettled{address: address}, %P.JudgeSettled{address: address}), do: true
  defp same_marker?(%P.LoopCompleted{address: address}, %P.LoopCompleted{address: address}), do: true
  defp same_marker?(_prior_payload, _payload), do: false

  # A loop iteration marker is positional per `(address, iteration)`, since the same
  # loop address is re-entered once per iteration.
  defp iteration_marker(run_id, seq, prior, node, iteration) do
    if journaled_iteration?(prior, node.address, iteration),
      do: seq,
      else: commit(run_id, seq, Event.iteration_started(node, iteration))
  end

  defp journaled_iteration?(prior, address, iteration) do
    Enum.any?(prior, fn
      %Event{payload: %P.IterationStarted{address: ^address, iteration: ^iteration}} -> true
      %Event{} -> false
    end)
  end

  defp journaled_accumulate?(prior, address, iteration) do
    Enum.any?(prior, fn
      %Event{payload: %P.Accumulate{address: ^address, iteration: ^iteration}} -> true
      %Event{} -> false
    end)
  end

  defp journaled_decision(prior, address, iteration, source_address) do
    case Enum.find_value(prior, fn
           %Event{
             payload:
               %P.LoopDecision{
                 address: ^address,
                 iteration: ^iteration,
                 source_address: ^source_address
               } = payload
           } ->
             payload

           %Event{} ->
             nil
         end) do
      nil -> :none
      payload -> {:ok, payload}
    end
  end

  defp commit(run_id, seq, %Event{} = event) do
    event = persist(run_id, event)
    max(seq, event.seq + 1)
  end

  defp persist(run_id, %Event{} = event) do
    {:ok, event} = Journal.append_next(run_id, event)
    # Post-commit broadcast so live read surfaces can subscribe.
    Phoenix.PubSub.broadcast(PubSub, "run:" <> run_id, {:journal_committed, run_id, event.seq})
    event
  end
end
