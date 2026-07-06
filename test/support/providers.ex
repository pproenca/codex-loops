defmodule Workflow.Test.EchoProvider do
  @moduledoc """
  A call-counting mock provider. Each invocation sends `{:agent_called, prompt}` to
  the pid in `opts[:sink]`, so a test can assert exactly how many times the
  provider ran, and returns an opaque (schemaless) result plus fixed usage.
  """
  @behaviour Workflow.Provider

  alias Workflow.Provider.Usage

  @impl true
  def run_agent(prompt, _schema, _key, opts) do
    if sink = Keyword.get(opts, :sink), do: send(sink, {:agent_called, prompt})
    {:ok, %{"echo" => prompt}, %Usage{input_tokens: 3, output_tokens: 5, total_tokens: 8}}
  end
end

defmodule Workflow.Test.GateProvider do
  @moduledoc """
  A provider that can block inside the agent turn until released, so a test can
  deterministically hold a run "in flight" and probe or take over the write lease.

  Every call pings `{:agent_called, prompt}` to `opts[:sink]`. It then blocks —
  sending `{:at_agent, self()}` (which, since the provider runs synchronously in
  the live writer, is the writer's own pid) and waiting for `:proceed` — but only
  when `opts[:gate_on]` matches: `:any` (the default) gates every turn, while a
  prompt string gates only that turn and lets the others pass straight through.
  Blocking turns bill nothing; passing turns bill fixed usage.
  """
  @behaviour Workflow.Provider

  alias Workflow.Provider.Usage

  @impl true
  def run_agent(prompt, _schema, _key, opts) do
    sink = Keyword.fetch!(opts, :sink)
    send(sink, {:agent_called, prompt})

    case Keyword.get(opts, :gate_on, :any) do
      gate when gate == :any or gate == prompt ->
        send(sink, {:at_agent, self()})
        receive do: (:proceed -> :ok)

      _other ->
        :ok
    end

    {:ok, %{}, %Usage{input_tokens: 1, output_tokens: 1, total_tokens: 2}}
  end
end

defmodule Workflow.Test.ScriptedProvider do
  @moduledoc """
  A call-counting mock that returns a *scripted sequence* of outputs — one per
  invocation — so a test can drive the fail-closed retry loop deterministically
  (e.g. `[invalid, invalid, valid]`). The remaining script lives in an `Agent`
  passed as `opts[:script]`; each call pops its head. Every call sends
  `{:agent_called, prompt}` to `opts[:sink]`, so the exact call count is asserted.
  """
  @behaviour Workflow.Provider

  alias Workflow.Provider.Usage

  @doc "Start a script `Agent` seeded with the outputs to return, in order."
  def start(outputs), do: Agent.start_link(fn -> outputs end)

  @impl true
  def run_agent(prompt, _schema, _key, opts) do
    if sink = Keyword.get(opts, :sink), do: send(sink, {:agent_called, prompt})
    output = Agent.get_and_update(Keyword.fetch!(opts, :script), fn [h | t] -> {h, t} end)
    {:ok, output, %Usage{input_tokens: 1, output_tokens: 1, total_tokens: 2}}
  end
end

defmodule Workflow.Test.FlakyProvider do
  @moduledoc """
  Returns a scripted sequence of outputs, then — once the script is exhausted —
  RAISES in the caller (the live writer) rather than crashing the script `Agent`.
  This simulates a provider fault mid-retry that crashes the writer while the
  already-committed paid attempts survive in the journal, so a test can resume the
  run and prove those attempts are not re-called. Every call pings `opts[:sink]`.
  """
  @behaviour Workflow.Provider

  alias Workflow.Provider.Usage

  @doc "Start a script `Agent` seeded with the outputs to return, in order."
  def start(outputs), do: Agent.start_link(fn -> outputs end)

  @impl true
  def run_agent(prompt, _schema, _key, opts) do
    if sink = Keyword.get(opts, :sink), do: send(sink, {:agent_called, prompt})

    case Agent.get_and_update(Keyword.fetch!(opts, :script), fn
           [] -> {:exhausted, []}
           [h | t] -> {h, t}
         end) do
      :exhausted -> raise "provider fault mid-retry"
      output -> {:ok, output, %Usage{input_tokens: 1, output_tokens: 1, total_tokens: 2}}
    end
  end
end

defmodule Workflow.Test.LedgeredProvider do
  @moduledoc """
  A key-deduping, charge-counting mock that models a real backend's server-side
  request idempotency. A shared `store` `Agent` records, per `Workflow.IdempotencyKey`,
  that the paid effect happened. The *first* call for a key charges (usage is
  billed once); any later call for the *same* key returns the identical result
  billed the same — modelling a dedup that replays the prior effect without
  charging a second time.

  With `opts[:crash_once]`, the first call for a fresh key records its charge and
  then hard-kills the caller — the live writer — *before returning*, reproducing
  the crash-between-provider-return-and-commit window: the effect happened
  server-side but no `agent_committed` ever lands. On resume the writer re-invokes
  with the same key, the store dedupes (`charges/2` stays at 1), and the commit
  finally lands — proving the paid effect is exactly-once and never dropped.
  """
  @behaviour Workflow.Provider

  alias Workflow.Provider.Usage

  @doc "Start the shared idempotency store."
  def start, do: Agent.start_link(fn -> %{charges: %{}, crashed: false} end)

  @doc "How many times the paid effect for `key` was actually charged (0 or 1)."
  def charges(store, key), do: Agent.get(store, &Map.get(&1.charges, key, 0))

  @impl true
  def run_agent(prompt, _schema, key, opts) do
    store = Keyword.fetch!(opts, :store)
    if sink = Keyword.get(opts, :sink), do: send(sink, {:agent_called, prompt})

    crash? =
      Agent.get_and_update(store, fn state ->
        if Map.has_key?(state.charges, key) do
          # Dedup: this key already paid — no new charge, no crash.
          {false, state}
        else
          crash? = Keyword.get(opts, :crash_once, false) and not state.crashed
          {crash?, %{state | charges: Map.put(state.charges, key, 1), crashed: state.crashed or crash?}}
        end
      end)

    # Kill the writer after the charge is durable server-side but before it commits.
    if crash?, do: Process.exit(self(), :kill)

    {:ok, %{"echo" => prompt}, %Usage{input_tokens: 1, output_tokens: 1, total_tokens: 2}}
  end
end

defmodule Workflow.Test.DedupingProvider do
  @moduledoc """
  A schema-aware, key-deduping, charge-counting mock modelling a real backend whose
  request-idempotency key is `Workflow.IdempotencyKey`. A shared `store` holds a
  scripted sequence of outputs plus a per-key ledger. The *first* call for a key
  pops the next scripted output, records it under the key, and charges once; any
  later call for the *same* key replays that recorded output without charging
  again.

  This exercises the fail-closed retry path against a deduping backend: because
  each retry attempt carries a *distinct* key (`attempt`), the backend serves a
  fresh scripted output to each attempt rather than replaying the first (rejected)
  one — so a schema-invalid first output can still be corrected on retry. A run
  that shared one key across attempts would dedupe every retry to attempt 0's
  output and never succeed.
  """
  @behaviour Workflow.Provider

  alias Workflow.Provider.Usage

  @doc "Start the shared store seeded with the outputs to return, in order."
  def start(outputs), do: Agent.start_link(fn -> %{script: outputs, results: %{}, charges: %{}} end)

  @doc "How many times the paid effect for `key` was actually charged (0 or 1)."
  def charges(store, key), do: Agent.get(store, &Map.get(&1.charges, key, 0))

  @impl true
  def run_agent(prompt, _schema, key, opts) do
    store = Keyword.fetch!(opts, :store)
    if sink = Keyword.get(opts, :sink), do: send(sink, {:agent_called, prompt})

    output =
      Agent.get_and_update(store, fn state ->
        case Map.fetch(state.results, key) do
          # Dedup: this key already paid — replay its output, charge nothing more.
          {:ok, recorded} ->
            {recorded, state}

          # Fresh key: pop the next scripted output, record it, charge once.
          :error ->
            [out | rest] = state.script

            {out,
             %{
               state
               | script: rest,
                 results: Map.put(state.results, key, out),
                 charges: Map.put(state.charges, key, 1)
             }}
        end
      end)

    {:ok, output, %Usage{input_tokens: 1, output_tokens: 1, total_tokens: 2}}
  end
end

defmodule Workflow.Test.ExplodingProvider do
  @moduledoc """
  Fails the test loudly if it is ever called. Used to prove exactly-once: on
  resume, a settled turn must be replayed from the journal, so this provider must
  never run.
  """
  @behaviour Workflow.Provider

  @impl true
  def run_agent(_prompt, _schema, _key, _opts),
    do: raise("provider was called when a journaled effect should have been replayed")
end
