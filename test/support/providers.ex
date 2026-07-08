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

          {crash?,
           %{state | charges: Map.put(state.charges, key, 1), crashed: state.crashed or crash?}}
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
  def start(outputs),
    do: Agent.start_link(fn -> %{script: outputs, results: %{}, charges: %{}} end)

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

defmodule Workflow.Test.LoopProvider do
  @moduledoc """
  A deduping, charge-counting mock for driving dynamic loops. A shared `store`
  `Agent` holds a scripted sequence of per-iteration outputs plus a per-key ledger
  (`Workflow.IdempotencyKey`). The *first* call for a fresh key pops the next
  scripted output, records it under the key, and charges once; any later call for
  the *same* key replays that recorded output without charging again — modelling a
  real backend's request idempotency so a loop iteration re-run after a lost commit
  is free and deterministic.

  With `opts[:crash_at]` set to an iteration index, the first (fresh) call for that
  iteration records its output durably in the store and then hard-kills the caller —
  the live writer — *before returning*, reproducing the return→commit crash window
  mid-loop: the effect happened but no `agent_committed`/`accumulate` landed for
  that round. On resume the writer re-invokes with the same key, the store dedupes
  (no re-pop, no new charge), and the round finally commits — proving the
  accumulator rebuilds with no lost or duplicated items.

  Every call pings `{:agent_called, prompt, iteration}` to `opts[:sink]`, so a test
  can assert the exact per-iteration call sequence.
  """
  @behaviour Workflow.Provider

  alias Workflow.Provider.Usage

  @doc "Start the shared store seeded with the per-iteration outputs to return, in order."
  def start(outputs),
    do: Agent.start_link(fn -> %{outputs: outputs, results: %{}, charges: %{}} end)

  @doc "How many times the paid effect for `key` was actually charged (0 or 1)."
  def charges(store, key), do: Agent.get(store, &Map.get(&1.charges, key, 0))

  @impl true
  def run_agent(prompt, _schema, key, opts) do
    store = Keyword.fetch!(opts, :store)
    if sink = Keyword.get(opts, :sink), do: send(sink, {:agent_called, prompt, key.iteration})

    {output, fresh?} =
      Agent.get_and_update(store, fn state ->
        case Map.fetch(state.results, key) do
          {:ok, recorded} ->
            {{recorded, false}, state}

          :error ->
            [out | rest] = state.outputs

            {{out, true},
             %{
               state
               | outputs: rest,
                 results: Map.put(state.results, key, out),
                 charges: Map.put(state.charges, key, 1)
             }}
        end
      end)

    # Kill the writer after the effect is durable server-side but before it commits.
    if fresh? and Keyword.get(opts, :crash_at) == key.iteration, do: Process.exit(self(), :kill)

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

defmodule Workflow.Test.ProviderFailureProvider do
  @moduledoc """
  Returns a SPEC-level expected provider failure instead of crashing the writer.

  Tests use this to prove provider-side quota/timeout/unavailable/model-limit
  failures are journaled as data, preserving usage and activity for the failed
  paid turn.
  """
  @behaviour Workflow.Provider

  alias Workflow.Provider.Usage

  @impl true
  def run_agent(prompt, _schema, key, opts) do
    if sink = Keyword.get(opts, :sink), do: send(sink, {:agent_called, prompt, key})

    kind = Keyword.get(opts, :kind, :timeout)
    detail = Keyword.get(opts, :detail, %{"message" => "provider timeout"})
    usage = Keyword.get(opts, :usage, %Usage{input_tokens: 4, output_tokens: 1, total_tokens: 5})

    activity =
      Keyword.get(opts, :activity, [
        %{kind: "provider", label: "Provider", summary: "expected failure", status: "failed"}
      ])

    {:error, {:provider_failure, kind, detail, usage, activity}}
  end
end

defmodule Workflow.Test.VerdictProvider do
  @moduledoc """
  A verify-panel mock that casts a **deterministic** verdict per voter, keyed on the
  voter's branch index (the last element of the idempotency key's `node_path`) rather
  than call order — so it is correct under the concurrent fan-out. `opts[:verdicts]`
  is a boolean list indexed by voter; each call pings `{:agent_called, prompt}` to
  `opts[:sink]` so the exact vote count is asserted.
  """
  @behaviour Workflow.Provider

  alias Workflow.Provider.Usage

  @impl true
  def run_agent(prompt, _schema, key, opts) do
    if sink = Keyword.get(opts, :sink), do: send(sink, {:agent_called, prompt})
    verdict = Enum.at(Keyword.fetch!(opts, :verdicts), List.last(key.node_path))
    {:ok, %{"verdict" => verdict}, %Usage{input_tokens: 1, output_tokens: 1, total_tokens: 2}}
  end
end

defmodule Workflow.Test.PanelProvider do
  @moduledoc """
  A judge-panel mock. A schema-backed call is a **scoring** turn: it returns a
  deterministic score keyed on the candidate index (`node_path` at position `-2`, i.e.
  `[judge, candidate, criterion]`) from `opts[:scores]` — deterministic under the
  concurrent grid, independent of call order. A schemaless call is the downstream
  **synthesis** turn and echoes its prompt. Every call pings `{:agent_called, prompt}`
  to `opts[:sink]`.
  """
  @behaviour Workflow.Provider

  alias Workflow.Provider.Usage

  @impl true
  def run_agent(prompt, nil, _key, opts) do
    if sink = Keyword.get(opts, :sink), do: send(sink, {:agent_called, prompt})
    {:ok, %{"synthesis" => prompt}, %Usage{input_tokens: 1, output_tokens: 1, total_tokens: 2}}
  end

  def run_agent(prompt, _schema, key, opts) do
    if sink = Keyword.get(opts, :sink), do: send(sink, {:agent_called, prompt})
    score = Enum.at(Keyword.fetch!(opts, :scores), Enum.at(key.node_path, -2))
    {:ok, %{"score" => score}, %Usage{input_tokens: 1, output_tokens: 1, total_tokens: 2}}
  end
end

defmodule Workflow.Test.RefineProvider do
  @moduledoc """
  Deterministic provider for refine V1 tests.

  Producer/reviser role calls return role-owned artifact envelopes, while reviewer
  calls return approval envelopes keyed by reviewer index. Every call reports the
  prompt and key to the sink so tests can prove the reviser was not invoked.
  """
  @behaviour Workflow.Provider

  alias Workflow.Provider.Usage

  @impl true
  def run_agent(prompt, _schema, key, opts) do
    if sink = Keyword.get(opts, :sink), do: send(sink, {:agent_called, prompt, key})
    activity_sink = Keyword.get(opts, :activity_sink, fn _entry -> :ok end)

    opts
    |> Keyword.get(:activity_entries, [])
    |> Enum.each(fn entry -> activity_sink.(entry) end)

    output =
      case key.node_path do
        [_refine_index, 0] ->
          %{"artifact" => Keyword.fetch!(opts, :artifact)}

        [_refine_index, 1, reviewer_index] ->
          reviews =
            case Keyword.fetch(opts, :review_rounds) do
              {:ok, rounds} -> Enum.at(rounds, key.iteration)
              :error -> Keyword.fetch!(opts, :reviews)
            end

          review = Enum.at(reviews, reviewer_index)

          %{
            "approved" => Keyword.fetch!(review, :approved),
            "findings" => Keyword.get(review, :findings, [])
          }

        [_refine_index, 2] ->
          artifact =
            case Keyword.fetch(opts, :revised_artifacts) do
              {:ok, artifacts} -> Enum.at(artifacts, key.iteration)
              :error -> Keyword.get(opts, :revised_artifact, "SHOULD NOT REVISE")
            end

          %{"artifact" => artifact}

        [_refine_index, 3] ->
          review = Keyword.fetch!(opts, :cold_read_review)

          %{
            "approved" => Keyword.fetch!(review, :approved),
            "findings" => Keyword.get(review, :findings, [])
          }

        [_refine_index, 4] ->
          %{"artifact" => Keyword.fetch!(opts, :repair_artifact)}
      end

    {:ok, output, %Usage{input_tokens: 1, output_tokens: 1, total_tokens: 2}}
  end
end
