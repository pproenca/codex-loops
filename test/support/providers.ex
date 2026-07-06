defmodule Workflow.Test.EchoProvider do
  @moduledoc """
  A call-counting mock provider. Each invocation sends `{:agent_called, prompt}` to
  the pid in `opts[:sink]`, so a test can assert exactly how many times the
  provider ran, and returns an opaque (schemaless) result plus fixed usage.
  """
  @behaviour Workflow.Provider

  alias Workflow.Provider.Usage

  @impl true
  def run_agent(prompt, _schema, opts) do
    if sink = Keyword.get(opts, :sink), do: send(sink, {:agent_called, prompt})
    {:ok, %{"echo" => prompt}, %Usage{input_tokens: 3, output_tokens: 5, total_tokens: 8}}
  end
end

defmodule Workflow.Test.GateProvider do
  @moduledoc """
  A provider that blocks inside the agent turn until released, so a test can
  deterministically hold a run "in flight" and probe the write lease. On call it
  sends `{:at_agent, self()}` to `opts[:sink]` and waits for `:proceed`.
  """
  @behaviour Workflow.Provider

  alias Workflow.Provider.Usage

  @impl true
  def run_agent(_prompt, _schema, opts) do
    send(Keyword.fetch!(opts, :sink), {:at_agent, self()})

    receive do
      :proceed -> :ok
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
  def run_agent(prompt, _schema, opts) do
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
  def run_agent(prompt, _schema, opts) do
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

defmodule Workflow.Test.ExplodingProvider do
  @moduledoc """
  Fails the test loudly if it is ever called. Used to prove exactly-once: on
  resume, a settled turn must be replayed from the journal, so this provider must
  never run.
  """
  @behaviour Workflow.Provider

  @impl true
  def run_agent(_prompt, _schema, _opts),
    do: raise("provider was called when a journaled effect should have been replayed")
end
