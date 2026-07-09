defmodule Workflow.Provider.Mock do
  @moduledoc """
  The default, offline provider: a deterministic echo that runs no external call.
  It is the `--provider mock` backend — used for dry runs and as the safe default
  when no real backend is configured — and, like every provider, it satisfies the
  `Workflow.Provider` contract so the interpreter drives it unchanged.

  It echoes the prompt and bills nothing, so a schemaless turn completes and a
  schema turn's output is decided entirely by the writer's fail-closed validation.
  """
  @behaviour Workflow.Provider

  alias Workflow.Provider.Usage

  @impl true
  def run_agent(prompt, _schema, _key, _opts), do: {:ok, %{"echo" => prompt}, %Usage{}}
end
