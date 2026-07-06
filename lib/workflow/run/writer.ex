defmodule Workflow.Run.Writer do
  @moduledoc """
  The single live writer for one run. It walks the inert tree, invokes the provider
  for agent nodes, and commits ordered events to the journal.

  It owns a genuine serialised resource — the per-run write lease and the `seq`
  cursor — which is exactly what a process is for. The lease is the registry name:
  `start_link/1` registers `{:via, Registry, {Registry, run_id}}`, so a second
  writer for the same `run_id` fails with `{:already_started, pid}`. The registry
  monitors this process, releasing the lease on death.

  Work runs in `handle_continue/2` (so `start_link` returns as soon as the lease is
  held), then the writer reports its result to the caller and stops `:normal`.
  Crashes propagate to the caller via its monitor — let it crash.
  """
  use GenServer, restart: :temporary

  alias Workflow.{Journal, Event, Idempotency, IdempotencyKey, PubSub}
  alias Workflow.Node.{Phase, Log, Agent, Return}

  def start_link(opts) do
    run_id = Keyword.fetch!(opts, :run_id)
    GenServer.start_link(__MODULE__, Map.new(opts), name: via(run_id))
  end

  @doc "The registry name that is this run's write lease."
  def via(run_id), do: {:via, Registry, {Workflow.Run.Registry, run_id}}

  @impl true
  def init(state), do: {:ok, state, {:continue, :execute}}

  @impl true
  def handle_continue(:execute, state) do
    result = execute(state)
    send(state.parent, {:run_finished, state.run_id, result})
    {:stop, :normal, state}
  end

  defp execute(%{run_id: run_id, tree: tree, provider: provider}) do
    prior = Journal.fold(run_id)
    seq = Journal.last_seq(run_id) + 1

    seq = commit(run_id, seq, Event.run_started(tree))

    {seq, return_value} =
      Enum.reduce(tree.nodes, {seq, nil}, fn node, {seq, return_value} ->
        run_node(node, run_id, provider, prior, seq, return_value)
      end)

    _seq = commit(run_id, seq, Event.run_completed(return_value))
    {:ok, run_id}
  end

  defp run_node(%Phase{} = node, run_id, _provider, _prior, seq, return_value),
    do: {commit(run_id, seq, Event.phase_entered(node)), return_value}

  defp run_node(%Log{} = node, run_id, _provider, _prior, seq, return_value),
    do: {commit(run_id, seq, Event.log_emitted(node)), return_value}

  defp run_node(%Return{} = node, _run_id, _provider, _prior, seq, _return_value),
    do: {seq, node.value}

  defp run_node(%Agent{} = node, run_id, provider, prior, seq, return_value) do
    iteration = 0

    case Idempotency.committed_effect(prior, node.address, iteration) do
      # Exactly-once: a committed turn is replayed from the journal, never re-run.
      {:ok, _result, _usage} ->
        {seq, return_value}

      :none ->
        {:ok, result, usage} = call_provider(provider, node.prompt)

        key = %IdempotencyKey{run_id: run_id, node_path: node.address, iteration: iteration}
        event = Event.agent_committed(node, iteration, key, result, usage)
        {commit(run_id, seq, event), return_value}
    end
  end

  defp call_provider({module, opts}, prompt), do: module.run_agent(prompt, opts)

  defp commit(run_id, seq, %Event{} = event) do
    event = %{event | run_id: run_id, seq: seq}
    :ok = Journal.append(run_id, seq, event)
    # Post-commit broadcast so live read surfaces can subscribe.
    Phoenix.PubSub.broadcast(PubSub, "run:" <> run_id, {:journal_committed, run_id, event})
    seq + 1
  end
end
