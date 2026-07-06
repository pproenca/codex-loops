defmodule Workflow.Run.Writer do
  @moduledoc """
  The single live writer for one run. It walks the inert tree, invokes the provider
  for agent nodes, and commits ordered events to the journal.

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
  """
  use GenServer, restart: :temporary

  alias Workflow.{Journal, Event, Idempotency, IdempotencyKey, Schema, Status, PubSub}
  alias Workflow.Node.{Phase, Log, Agent, Return, Parallel, Pipeline}

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
        run_tree(run_id, tree, provider, prior, Map.get(state, :budget))
    end
  end

  defp run_tree(run_id, tree, provider, prior, budget) do
    seq = Journal.last_seq(run_id) + 1

    # A fresh run gets its start marker (carrying the budget target); a resume
    # already carries one, so appending another would falsely re-mark the folded
    # run as `:running` and re-declare a target the ledger already folded.
    seq = if prior == [], do: commit(run_id, seq, Event.run_started(tree, budget)), else: seq

    outcome =
      Enum.reduce_while(tree.nodes, {seq, nil}, fn node, {seq, return_value} ->
        case run_node(node, run_id, provider, prior, seq, return_value) do
          {:cont, seq, return_value} -> {:cont, {seq, return_value}}
          {:halt, seq, reason} -> {:halt, {:failed, seq, reason}}
        end
      end)

    case outcome do
      # A node failed closed: its terminal `agent_failed` is already journaled.
      {:failed, _seq, reason} ->
        {:error, reason}

      {seq, return_value} ->
        _seq = commit(run_id, seq, Event.run_completed(return_value))
        {:ok, run_id}
    end
  end

  defp run_node(%Phase{} = node, run_id, _provider, prior, seq, return_value),
    do: {:cont, commit_marker(run_id, seq, prior, Event.phase_entered(node)), return_value}

  defp run_node(%Log{} = node, run_id, _provider, prior, seq, return_value),
    do: {:cont, commit_marker(run_id, seq, prior, Event.log_emitted(node)), return_value}

  defp run_node(%Return{} = node, _run_id, _provider, _prior, seq, _return_value),
    do: {:cont, seq, node.value}

  # The sequential agent path commits each paid attempt *incrementally* — a rejection
  # lands in the journal before the next paid call runs — so a crash mid-retry
  # durably preserves the already-paid attempts and resume never re-pays them (proven
  # against a non-deduping provider). Concurrent lanes below can't commit off-thread,
  # so they instead lean on the provider's key-dedup for the same exactly-once
  # guarantee (#5's boundary), regenerating rejections idempotently on resume.
  defp run_node(%Agent{} = node, run_id, provider, prior, seq, return_value) do
    iteration = 0

    case Idempotency.resolve(prior, node.address, iteration) do
      # Exactly-once: a settled turn is replayed from the journal, never re-run.
      {:committed, _result, _usage} ->
        {:cont, seq, return_value}

      {:failed, reason} ->
        {:halt, seq, {:malformed_output, node.address, reason}}

      # Mid-flight resume: pick the retry loop back up at the first un-journaled
      # attempt rather than re-calling the provider for already-ledgered rejections.
      {:resume, next} ->
        commit_attempt(node, run_id, provider, seq, iteration, next, return_value)

      :none ->
        commit_attempt(node, run_id, provider, seq, iteration, 0, return_value)
    end
  end

  # Barrier fan-out: bracket the concurrent region with started/completed markers,
  # run every branch concurrently under the cap (bounded by the static branch list),
  # then commit each branch's journalled events in branch order. Branches build their
  # events off-thread and never touch the journal — only this single writer commits,
  # preserving the one-writer-per-run `seq` invariant.
  defp run_node(%Parallel{} = node, run_id, provider, prior, seq, return_value) do
    seq = commit_marker(run_id, seq, prior, Event.parallel_started(node))
    cap = node.max_concurrency || max(length(node.branches), 1)

    results =
      run_concurrently(node.branches, cap, fn branch ->
        to_lane_result(build_agent(branch, run_id, provider, prior))
      end)

    case commit_lanes(results, run_id, seq) do
      {:ok, seq} -> {:cont, commit_marker(run_id, seq, prior, Event.parallel_completed(node)), return_value}
      {:halt, seq, reason} -> {:halt, seq, reason}
    end
  end

  # Per-item fan-out: each lane runs its stages sequentially and independently; lanes
  # run concurrently under the cap with no cross-item barrier. Same single-writer
  # commit discipline as `parallel`.
  defp run_node(%Pipeline{} = node, run_id, provider, prior, seq, return_value) do
    seq = commit_marker(run_id, seq, prior, Event.pipeline_started(node))
    cap = node.max_concurrency || max(length(node.lanes), 1)

    results =
      run_concurrently(node.lanes, cap, fn lane ->
        run_lane(lane, run_id, provider, prior)
      end)

    case commit_lanes(results, run_id, seq) do
      {:ok, seq} -> {:cont, commit_marker(run_id, seq, prior, Event.pipeline_completed(node)), return_value}
      {:halt, seq, reason} -> {:halt, seq, reason}
    end
  end

  # Bounded, ordered fan-out. `ordered: true` keeps results in input order so the
  # writer commits lanes deterministically regardless of completion order.
  defp run_concurrently(inputs, cap, fun) do
    inputs
    |> Task.async_stream(fun, max_concurrency: cap, ordered: true, timeout: @fanout_timeout)
    |> Enum.map(fn {:ok, result} -> result end)
  end

  # A lane is a sequence of agents run in order, accumulating uncommitted events. A
  # failed stage halts the lane (its terminal `agent_failed` is included).
  defp run_lane(lane, run_id, provider, prior) do
    Enum.reduce_while(lane, {:ok, []}, fn agent, {:ok, acc} ->
      case build_agent(agent, run_id, provider, prior) do
        {:ok, events, _result} -> {:cont, {:ok, acc ++ events}}
        {:failed, events, reason} -> {:halt, {:failed, acc ++ events, reason}}
      end
    end)
  end

  defp to_lane_result({:ok, events, _result}), do: {:ok, events}
  defp to_lane_result({:failed, events, reason}), do: {:failed, events, reason}

  # Commit every lane's events in order — so all concurrent paid effects are
  # journaled even when a sibling lane failed — then halt with the first failure.
  defp commit_lanes(results, run_id, seq) do
    {seq, failure} =
      Enum.reduce(results, {seq, nil}, fn
        {:ok, events}, {seq, failure} -> {commit_all(run_id, seq, events), failure}
        {:failed, events, reason}, {seq, failure} -> {commit_all(run_id, seq, events), failure || reason}
      end)

    case failure do
      nil -> {:ok, seq}
      reason -> {:halt, seq, reason}
    end
  end

  # --- Sequential agent turn: commits each paid attempt as it happens ---

  # A schemaless turn proceeds on any output; a schema-backed turn is fail-closed
  # with on-thread retry up to `node.retries`. Each attempt is committed before the
  # next paid call, so a crash preserves the journalled attempts.
  defp commit_attempt(%Agent{schema: nil} = node, run_id, provider, seq, iteration, attempt, return_value) do
    key = key(run_id, node.address, iteration, attempt)
    {:ok, result, usage} = call_provider(provider, node.prompt, nil, key)
    {:cont, commit(run_id, seq, Event.agent_committed(node, iteration, key, result, usage)), return_value}
  end

  defp commit_attempt(%Agent{} = node, run_id, provider, seq, iteration, attempt, return_value) do
    key = key(run_id, node.address, iteration, attempt)
    {:ok, output, usage} = call_provider(provider, node.prompt, node.schema, key)

    case Schema.validate(node.schema, output) do
      {:ok, validated} ->
        event = Event.agent_committed(node, iteration, key, validated, usage)
        {:cont, commit(run_id, seq, event), return_value}

      {:error, reason} ->
        rejected = Event.agent_attempt_rejected(node, iteration, attempt, output, reason, usage)
        seq = commit(run_id, seq, rejected)

        if attempt < node.retries do
          commit_attempt(node, run_id, provider, seq, iteration, attempt + 1, return_value)
        else
          event = Event.agent_failed(node, iteration, attempt + 1, reason)
          {:halt, commit(run_id, seq, event), {:malformed_output, node.address, reason}}
        end
    end
  end

  # --- Concurrent agent turn: builds events off-thread for the writer to commit ---

  # Same turn semantics, but events are *accumulated* rather than committed, because a
  # fan-out branch runs in a Task and only the single writer may touch the journal.
  # Exactly-once is resolved purely from `prior`: a settled turn is replayed.
  defp build_agent(%Agent{} = node, run_id, provider, prior) do
    iteration = 0

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
          {:failed, Enum.reverse([failed, rejected | acc]), {:malformed_output, node.address, reason}}
        end
    end
  end

  defp key(run_id, address, iteration, attempt),
    do: %IdempotencyKey{run_id: run_id, node_path: address, iteration: iteration, attempt: attempt}

  # Commit a list of pre-built events in order, threading `seq`.
  defp commit_all(run_id, seq, events),
    do: Enum.reduce(events, seq, fn event, seq -> commit(run_id, seq, event) end)

  defp call_provider({module, opts}, prompt, schema, key),
    do: module.run_agent(prompt, schema, key, opts)

  # A structural marker (phase/log entry, fan-out bracket) is a *positional* event:
  # its identity is `(type, address)`, not a paid-effect key. On a fresh walk it is
  # committed; on resume the tree is re-walked from the top, so any marker already
  # journaled at this address is reused verbatim rather than re-emitted. This mirrors
  # the agent path's `Idempotency.resolve` guard, keeping the log additive and its
  # started↔completed brackets exactly-once so a pure fold that pairs or counts them
  # never double-brackets a fan-out region after a mid-run crash + resume.
  defp commit_marker(run_id, seq, prior, %Event{type: type, payload: %{address: address}} = event) do
    if journaled_marker?(prior, type, address), do: seq, else: commit(run_id, seq, event)
  end

  defp journaled_marker?(prior, type, address) do
    Enum.any?(prior, fn event ->
      event.type == type and Map.get(event.payload, :address) == address
    end)
  end

  defp commit(run_id, seq, %Event{} = event) do
    event = %{event | run_id: run_id, seq: seq}
    :ok = Journal.append(run_id, seq, event)
    # Post-commit broadcast so live read surfaces can subscribe.
    Phoenix.PubSub.broadcast(PubSub, "run:" <> run_id, {:journal_committed, run_id, event})
    seq + 1
  end
end
