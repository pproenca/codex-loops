defmodule Workflow.Test.EchoProvider do
  @moduledoc """
  A call-counting mock provider. Each invocation sends `{:agent_called, prompt}` to
  the pid in `opts[:sink]`, so a test can assert exactly how many times the
  provider ran, and returns an opaque (schemaless) result plus fixed usage.
  """
  @behaviour Workflow.Provider

  alias Workflow.Provider.Usage

  @impl true
  def run_agent(prompt, opts) do
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
  def run_agent(_prompt, opts) do
    send(Keyword.fetch!(opts, :sink), {:at_agent, self()})

    receive do
      :proceed -> :ok
    end

    {:ok, %{}, %Usage{input_tokens: 1, output_tokens: 1, total_tokens: 2}}
  end
end
