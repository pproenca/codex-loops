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
  alias Workflow.Node.{Phase, Log, Agent, Return}

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

  defp run_node(%Phase{} = node, run_id, _provider, _prior, seq, return_value),
    do: {:cont, commit(run_id, seq, Event.phase_entered(node)), return_value}

  defp run_node(%Log{} = node, run_id, _provider, _prior, seq, return_value),
    do: {:cont, commit(run_id, seq, Event.log_emitted(node)), return_value}

  defp run_node(%Return{} = node, _run_id, _provider, _prior, seq, _return_value),
    do: {:cont, seq, node.value}

  defp run_node(%Agent{} = node, run_id, provider, prior, seq, return_value) do
    iteration = 0

    case Idempotency.resolve(prior, node.address, iteration) do
      # Exactly-once: a settled turn is replayed from the journal, never re-run.
      {:committed, _result, _usage} ->
        {:cont, seq, return_value}

      {:failed, reason} ->
        {:halt, seq, {:malformed_output, node.address, reason}}

      # Mid-flight resume: the first `next` attempts already paid and journaled a
      # rejection, so pick the loop back up at `next` — never re-call the provider
      # for an attempt the journal already ledgered.
      {:resume, next} ->
        attempt(node, run_id, provider, seq, iteration, next, return_value)

      :none ->
        attempt(node, run_id, provider, seq, iteration, 0, return_value)
    end
  end

  # A schemaless turn proceeds on any output; a schema-backed turn is fail-closed
  # with on-thread retry up to `node.retries`. On valid output, commit and
  # continue; on invalid, journal the rejection and retry until the budget is
  # spent, then fail the node.
  defp attempt(%Agent{schema: nil} = node, run_id, provider, seq, iteration, attempt, return_value) do
    # The key is minted *before* the paid call and handed to the provider, so a
    # server-side dedupe closes the return→commit crash window (see `Provider`).
    # A schemaless turn is a single paid call, so `attempt` is always 0.
    key = key(run_id, node.address, iteration, attempt)
    {:ok, result, usage} = call_provider(provider, node.prompt, nil, key)
    {:cont, commit(run_id, seq, Event.agent_committed(node, iteration, key, result, usage)), return_value}
  end

  defp attempt(%Agent{} = node, run_id, provider, seq, iteration, attempt, return_value) do
    # Each retry is a distinct paid call, so it carries a distinct request key
    # (`attempt`). This keeps retries independent from a deduping backend, while a
    # crash-and-resume of the *same* attempt re-issues the identical key and dedupes.
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
          attempt(node, run_id, provider, seq, iteration, attempt + 1, return_value)
        else
          event = Event.agent_failed(node, iteration, attempt + 1, reason)
          {:halt, commit(run_id, seq, event), {:malformed_output, node.address, reason}}
        end
    end
  end

  defp key(run_id, address, iteration, attempt),
    do: %IdempotencyKey{run_id: run_id, node_path: address, iteration: iteration, attempt: attempt}

  defp call_provider({module, opts}, prompt, schema, key),
    do: module.run_agent(prompt, schema, key, opts)

  defp commit(run_id, seq, %Event{} = event) do
    event = %{event | run_id: run_id, seq: seq}
    :ok = Journal.append(run_id, seq, event)
    # Post-commit broadcast so live read surfaces can subscribe.
    Phoenix.PubSub.broadcast(PubSub, "run:" <> run_id, {:journal_committed, run_id, event})
    seq + 1
  end
end
