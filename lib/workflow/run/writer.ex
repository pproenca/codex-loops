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
  caller, and stops `:normal`. Crashes propagate to the caller via its monitor —
  let it crash.

  ## Execution context

  A small context threads through the walk: the `seq` cursor, the pending `return`
  value, the current loop `iteration` (0 at top level, the real per-iteration key
  component inside a loop), the enclosing loop's `seen_by` dedup field list, and the
  most recent agent result (`last_result`) that a `collect` reduces. It carries no
  authoritative state — every decision that matters is journaled and re-derivable by
  folding the log.
  """
  use GenServer, restart: :temporary

  alias Workflow.{
    Journal,
    Event,
    Idempotency,
    IdempotencyKey,
    Schema,
    Status,
    Ledger,
    Accumulator,
    Predicate,
    PubSub
  }

  alias Workflow.Node.{
    Phase,
    Log,
    Agent,
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

  # The agent turn is capped by `retries` on-thread, so a bounded fan-out timeout is
  # unnecessary; concurrent branches simply wait on their (mock or real) provider.
  @fanout_timeout :infinity

  def start_link(opts) do
    run_id = Keyword.fetch!(opts, :run_id)
    GenServer.start_link(__MODULE__, Map.new(opts), name: via(run_id))
  end

  @doc "The registry name that is this run's write lease."
  def via(run_id), do: {:via, Registry, {Workflow.Run.Registry, run_id}}

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_info(:begin, state) do
    result = execute(state)
    send(state.parent, {:run_finished, state.run_id, result})
    {:stop, :normal, state}
  end

  defp execute(%{run_id: run_id, tree: tree, provider: provider} = state) do
    prior = Journal.fold(run_id)

    # Resume is a pure fold. If the journal already folds to a terminal state, that
    # state is reused verbatim: no fresh `run_started` is appended (which would
    # un-terminate the read model) and no settled turn is re-run.
    case Status.fold(prior, run_id) do
      %Status{state: :completed} ->
        {:ok, run_id}

      %Status{state: :failed, failure: failure} ->
        {:error, {:malformed_output, failure.address, failure.reason}}

      %Status{} ->
        run_tree(run_id, tree, provider, prior, Map.get(state, :budget), Map.get(state, :script_path))
    end
  end

  defp run_tree(run_id, tree, provider, prior, budget, script_path) do
    seq = Journal.last_seq(run_id) + 1

    # A fresh run gets its start marker (carrying the budget target and the source
    # path); a resume already carries one, so appending another would falsely
    # re-mark the folded run as `:running` and re-declare a target the ledger
    # already folded.
    seq =
      if prior == [],
        do: commit(run_id, seq, Event.run_started(tree, budget, script_path)),
        else: seq

    ctx = %{seq: seq, return: nil, last_result: nil, iteration: 0, seen_by: []}

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
        {:halt, ctx, reason} -> {:halt, {:halt, ctx, reason}}
      end
    end)
  end

  defp run_node(%Phase{} = node, run_id, _provider, prior, ctx),
    do: {:cont, %{ctx | seq: commit_marker(run_id, ctx.seq, prior, Event.phase_entered(node))}}

  defp run_node(%Log{} = node, run_id, _provider, prior, ctx),
    do: {:cont, %{ctx | seq: commit_marker(run_id, ctx.seq, prior, Event.log_emitted(node))}}

  defp run_node(%Return{} = node, _run_id, _provider, _prior, ctx),
    do: {:cont, %{ctx | return: node.value}}

  # The sequential agent path commits each paid attempt *incrementally* — a rejection
  # lands in the journal before the next paid call runs — so a crash mid-retry
  # durably preserves the already-paid attempts and resume never re-pays them. The
  # committed/replayed result becomes `last_result`, which a following `collect` in
  # the same iteration harvests.
  defp run_node(%Agent{} = node, run_id, provider, prior, ctx) do
    iteration = ctx.iteration

    case Idempotency.resolve(prior, node.address, iteration) do
      # Exactly-once: a settled turn is replayed from the journal, never re-run.
      {:committed, result, _usage} ->
        {:cont, %{ctx | last_result: result}}

      {:failed, reason} ->
        {:halt, ctx, {:malformed_output, node.address, reason}}

      # Mid-flight resume: pick the retry loop back up at the first un-journaled
      # attempt rather than re-calling the provider for already-ledgered rejections.
      {:resume, next} ->
        commit_attempt(node, run_id, provider, ctx, iteration, next)

      :none ->
        commit_attempt(node, run_id, provider, ctx, iteration, 0)
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

  # `while_budget`: loop while the ledger's `remaining` exceeds `reserve` (and any
  # `until` predicate stays false). Termination is guaranteed — `remaining` only
  # falls — and bounded by `max_iterations` regardless.
  defp run_node(%WhileBudget{} = node, run_id, provider, prior, ctx),
    do: loop(node, [], run_id, provider, prior, ctx, 0)

  # `until_dry`: loop until `rounds` consecutive iterations add nothing new,
  # deduping by `seen_by`; bounded by `max_iterations`.
  defp run_node(%UntilDry{} = node, run_id, provider, prior, ctx),
    do: loop(node, node.seen_by, run_id, provider, prior, ctx, 0)

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

  # Synthesis is one schemaless, exactly-once agent turn whose effective prompt
  # deterministically embeds the literal inputs; it reuses the ordinary agent path
  # verbatim, so it is journaled, keyed, and resumable with no special case.
  defp run_node(%Synthesize{} = node, run_id, provider, prior, ctx) do
    agent = %Agent{address: node.address, prompt: synthesis_prompt(node), schema: nil, retries: 0}
    run_node(agent, run_id, provider, prior, ctx)
  end

  # Budget-scaled fan-out: decide (and journal) the width once, then run that many
  # branches concurrently under the cap, each a lane over the body re-addressed to
  # `parent ++ [branch, stage]`.
  defp run_node(%FanOut{} = node, run_id, provider, prior, ctx) do
    {width, seq} = decide_width(node, run_id, prior, ctx.seq)
    branches = for i <- 0..(width - 1)//1, do: rebase_body(node.body, node.address ++ [i])
    cap = node.max_concurrency || max(width, 1)

    results =
      run_concurrently(branches, cap, fn lane ->
        run_lane(lane, run_id, provider, prior, ctx.iteration)
      end)

    case commit_lanes(results, run_id, seq) do
      {:ok, seq} ->
        {:cont, %{ctx | seq: commit_marker(run_id, seq, prior, Event.fan_out_completed(node))}}

      {:halt, seq, reason} ->
        {:halt, %{ctx | seq: seq}, reason}
    end
  end

  # --- Verify / judge tally (pure folds over each panel's committed results) ---

  defp confirmed?(vote), do: Map.get(vote, "verdict") == true

  defp survives?(confirmations, total, :majority), do: confirmations * 2 > total
  defp survives?(confirmations, total, :unanimous), do: confirmations == total
  defp survives?(confirmations, _total, :any), do: confirmations >= 1
  defp survives?(confirmations, _total, n) when is_integer(n), do: confirmations >= n

  # A candidate's total is the sum of its per-criterion scores.
  defp score_lane(lane, run_id, provider, prior, iteration) do
    Enum.reduce_while(lane, {:ok, [], 0}, fn agent, {:ok, events, total} ->
      case build_agent(agent, run_id, provider, prior, iteration) do
        {:ok, evs, result} -> {:cont, {:ok, events ++ evs, total + Map.get(result, "score", 0)}}
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
    {seq, results, failure} =
      Enum.reduce(outcomes, {seq, [], nil}, fn
        {:ok, events, result}, {seq, results, failure} ->
          {commit_all(run_id, seq, events), [result | results], failure}

        {:failed, events, reason}, {seq, results, failure} ->
          {commit_all(run_id, seq, events), results, failure || reason}
      end)

    case failure do
      nil -> {:ok, seq, Enum.reverse(results)}
      reason -> {:halt, seq, reason}
    end
  end

  defp synthesis_prompt(%Synthesize{inputs: inputs, prompt: prompt}),
    do: "#{prompt}\n\nInputs: #{inspect(inputs)}"

  # --- Budget-scaled fan-out width (a journaled runtime decision) ---

  # Decide the width once and journal it; a resume replays the journaled width rather
  # than recomputing `floor(remaining / per)` against a ledger the branches have
  # since spent down.
  defp decide_width(%FanOut{} = node, run_id, prior, seq) do
    case journaled_fan_out_width(prior, node.address) do
      {:ok, width} ->
        {width, seq}

      :none ->
        width = compute_width(node.width, run_id)
        {width, commit(run_id, seq, Event.fan_out_started(node, width))}
    end
  end

  defp compute_width(%BudgetSlices{per: per}, run_id) do
    case Ledger.remaining(Ledger.of(run_id)) do
      :infinity ->
        raise ArgumentError, "budget_slices requires a bounded run (no budget target set)"

      remaining ->
        div(max(remaining, 0), per)
    end
  end

  defp journaled_fan_out_width(prior, address) do
    case Enum.find(prior, fn e -> e.type == :fan_out_started and e.payload.address == address end) do
      nil -> :none
      event -> {:ok, event.payload.width}
    end
  end

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
    {decision, ctx} = decide(node, run_id, prior, ctx, iteration)

    case decision do
      :stop ->
        {:cont,
         %{
           ctx
           | seq: commit_marker(run_id, ctx.seq, prior, Event.loop_completed(node, iteration))
         }}

      :continue ->
        seq = iteration_marker(run_id, ctx.seq, prior, node, iteration)
        body_ctx = %{ctx | seq: seq, iteration: iteration, seen_by: seen_by, last_result: nil}

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

          {:halt, body_ctx, reason} ->
            {:halt, %{ctx | seq: body_ctx.seq}, reason}
        end
    end
  end

  # Replay a journaled decision verbatim; only compute (and journal) a fresh one when
  # this iteration has never been decided.
  defp decide(node, run_id, prior, ctx, iteration) do
    case journaled_decision(prior, node.address, iteration) do
      {:ok, decision} ->
        {decision, ctx}

      :none ->
        decision = fresh_decision(node, run_id, iteration)

        {decision,
         %{ctx | seq: commit(run_id, ctx.seq, Event.loop_decision(node, iteration, decision))}}
    end
  end

  defp fresh_decision(%WhileBudget{} = node, run_id, iteration) do
    cond do
      iteration >= node.max_iterations -> :stop
      node.until && Predicate.evaluate(node.until, predicate_context(run_id)) -> :stop
      Ledger.remaining(Ledger.of(run_id)) > node.reserve -> :continue
      true -> :stop
    end
  end

  defp fresh_decision(%UntilDry{} = node, run_id, iteration) do
    cond do
      iteration >= node.max_iterations -> :stop
      dry_streak(run_id, node.address, iteration) >= node.rounds -> :stop
      true -> :continue
    end
  end

  defp predicate_context(run_id) do
    %{accumulators: Accumulator.of(run_id), remaining: Ledger.remaining(Ledger.of(run_id))}
  end

  # Consecutive most-recent iterations (ending at `iteration - 1`) whose `collect`s
  # added nothing — derived purely from the journal, never from re-run agent output.
  defp dry_streak(run_id, loop_address, iteration) do
    added_by_round =
      run_id
      |> Journal.fold()
      |> Enum.filter(
        &(&1.type == :accumulate and List.starts_with?(&1.payload.address, loop_address))
      )
      |> Enum.group_by(& &1.payload.iteration, &length(&1.payload.added))
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
    inputs
    |> Task.async_stream(fun, max_concurrency: cap, ordered: true, timeout: @fanout_timeout)
    |> Enum.map(fn {:ok, result} -> result end)
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

  defp commit_attempt(%Agent{schema: nil} = node, run_id, provider, ctx, iteration, attempt) do
    key = key(run_id, node.address, iteration, attempt)
    {:ok, result, usage} = call_provider(provider, node.prompt, nil, key)
    seq = commit(run_id, ctx.seq, Event.agent_committed(node, iteration, key, result, usage))
    {:cont, %{ctx | seq: seq, last_result: result}}
  end

  defp commit_attempt(%Agent{} = node, run_id, provider, ctx, iteration, attempt) do
    key = key(run_id, node.address, iteration, attempt)
    {:ok, output, usage} = call_provider(provider, node.prompt, node.schema, key)

    case Schema.validate(node.schema, output) do
      {:ok, validated} ->
        seq =
          commit(run_id, ctx.seq, Event.agent_committed(node, iteration, key, validated, usage))

        {:cont, %{ctx | seq: seq, last_result: validated}}

      {:error, reason} ->
        seq =
          commit(
            run_id,
            ctx.seq,
            Event.agent_attempt_rejected(node, iteration, attempt, output, reason, usage)
          )

        if attempt < node.retries do
          commit_attempt(node, run_id, provider, %{ctx | seq: seq}, iteration, attempt + 1)
        else
          seq = commit(run_id, seq, Event.agent_failed(node, iteration, attempt + 1, reason))
          {:halt, %{ctx | seq: seq}, {:malformed_output, node.address, reason}}
        end
    end
  end

  # --- Concurrent agent turn: builds events off-thread for the writer to commit ---

  defp build_agent(%Agent{} = node, run_id, provider, prior, iteration) do
    case Idempotency.resolve(prior, node.address, iteration) do
      {:committed, result, _usage} -> {:ok, [], result}
      {:failed, reason} -> {:failed, [], {:malformed_output, node.address, reason}}
      {:resume, next} -> build_attempt(node, run_id, provider, iteration, next, [])
      :none -> build_attempt(node, run_id, provider, iteration, 0, [])
    end
  end

  defp build_attempt(%Agent{schema: nil} = node, run_id, provider, iteration, attempt, _acc) do
    key = key(run_id, node.address, iteration, attempt)
    {:ok, result, usage} = call_provider(provider, node.prompt, nil, key)
    {:ok, [Event.agent_committed(node, iteration, key, result, usage)], result}
  end

  defp build_attempt(%Agent{} = node, run_id, provider, iteration, attempt, acc) do
    key = key(run_id, node.address, iteration, attempt)
    {:ok, output, usage} = call_provider(provider, node.prompt, node.schema, key)

    case Schema.validate(node.schema, output) do
      {:ok, validated} ->
        committed = Event.agent_committed(node, iteration, key, validated, usage)
        {:ok, Enum.reverse([committed | acc]), validated}

      {:error, reason} ->
        rejected = Event.agent_attempt_rejected(node, iteration, attempt, output, reason, usage)

        if attempt < node.retries do
          build_attempt(node, run_id, provider, iteration, attempt + 1, [rejected | acc])
        else
          failed = Event.agent_failed(node, iteration, attempt + 1, reason)

          {:failed, Enum.reverse([failed, rejected | acc]),
           {:malformed_output, node.address, reason}}
        end
    end
  end

  defp key(run_id, address, iteration, attempt),
    do: %IdempotencyKey{
      run_id: run_id,
      node_path: address,
      iteration: iteration,
      attempt: attempt
    }

  defp commit_all(run_id, seq, events),
    do: Enum.reduce(events, seq, fn event, seq -> commit(run_id, seq, event) end)

  defp call_provider({module, opts}, prompt, schema, key),
    do: module.run_agent(prompt, schema, key, opts)

  # --- Journal idempotency for positional (non-paid) events ---

  # A structural marker (phase/log entry, fan-out or loop bracket) is a *positional*
  # event: its identity is `(type, address)`. On a fresh walk it is committed; on
  # resume the tree is re-walked from the top, so any marker already journaled at this
  # address is reused verbatim rather than re-emitted.
  defp commit_marker(run_id, seq, prior, %Event{type: type, payload: %{address: address}} = event) do
    if journaled_marker?(prior, type, address), do: seq, else: commit(run_id, seq, event)
  end

  defp journaled_marker?(prior, type, address) do
    Enum.any?(prior, fn event ->
      event.type == type and Map.get(event.payload, :address) == address
    end)
  end

  # A loop iteration marker is positional per `(address, iteration)`, since the same
  # loop address is re-entered once per iteration.
  defp iteration_marker(run_id, seq, prior, node, iteration) do
    if journaled_iteration?(prior, node.address, iteration),
      do: seq,
      else: commit(run_id, seq, Event.iteration_started(node, iteration))
  end

  defp journaled_iteration?(prior, address, iteration) do
    Enum.any?(prior, fn event ->
      event.type == :iteration_started and event.payload.address == address and
        event.payload.iteration == iteration
    end)
  end

  defp journaled_accumulate?(prior, address, iteration) do
    Enum.any?(prior, fn event ->
      event.type == :accumulate and event.payload.address == address and
        event.payload.iteration == iteration
    end)
  end

  defp journaled_decision(prior, address, iteration) do
    case Enum.find(prior, fn event ->
           event.type == :loop_decision and event.payload.address == address and
             event.payload.iteration == iteration
         end) do
      nil -> :none
      event -> {:ok, event.payload.decision}
    end
  end

  defp commit(run_id, seq, %Event{} = event) do
    event = %{event | run_id: run_id, seq: seq}
    :ok = Journal.append(run_id, seq, event)
    # Post-commit broadcast so live read surfaces can subscribe.
    Phoenix.PubSub.broadcast(PubSub, "run:" <> run_id, {:journal_committed, run_id, event})
    seq + 1
  end
end
