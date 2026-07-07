defmodule Workflow.Provider do
  @moduledoc """
  The contract an agent backend must satisfy. `schema` is the raw JSON-schema map
  the caller wants the output to conform to, or `nil` for a schemaless turn — a
  real backend uses it to request structured output; the runner independently
  validates and, on failure, retries or fails the node (the provider never sees
  retry policy). Every call reports `Usage` so the budget ledger can fold over
  agent events.

  ## The idempotency key closes the return→commit window

  Every call carries the paid effect's `Workflow.IdempotencyKey` — `(run_id,
  node_path, iteration)` refined by the `attempt` (retry) index, so each distinct
  paid call — including each fail-closed retry — reaches the backend under a
  distinct request key. The runner already reuses a *committed* turn from the
  journal, so the provider is only ever invoked for a turn with no committed
  result. But there is a narrow window between the provider returning and the
  writer committing that result: if the writer crashes there, the effect happened
  but was never journaled, and a naive resume would re-invoke the provider and
  **double-spend**.

  A real backend uses this key as its own request-idempotency key (the same key
  OpenAI/Codex accepts) so a re-issued request after a lost commit returns the
  already-produced result **without charging again**. That makes the paid effect
  exactly-once across the return→commit crash: the money is spent at most once and
  the result is never dropped, because resume re-runs the (now free) deduped call
  and commits it.
  """

  @type result :: term()
  @type activity :: [
          %{
            optional(:kind) => String.t(),
            optional(:label) => String.t(),
            optional(:summary) => String.t(),
            optional(:status) => String.t()
          }
        ]

  @callback run_agent(
              prompt :: String.t(),
              schema :: map() | nil,
              key :: Workflow.IdempotencyKey.t(),
              opts :: term()
            ) ::
              {:ok, result(), Workflow.Provider.Usage.t()}
              | {:ok, result(), Workflow.Provider.Usage.t(), activity()}

  @typedoc "A resolved backend: the provider module plus its opaque per-run opts."
  @type t :: {module(), term()}

  @doc """
  Resolve a backend name (the `--provider` flag) into a `{module, opts}` port the
  interpreter can drive. This is the whole of provider selection: swapping `:mock`
  for `:codex` changes only which module the writer calls — never any core, writer,
  or fold code — so the two backends are interchangeable behind one port.
  """
  @spec select(:mock | :codex, keyword()) :: t()
  def select(:mock, opts), do: {Workflow.Provider.Mock, opts}
  def select(:codex, opts), do: {Workflow.Provider.Codex, opts}
end

defmodule Workflow.Provider.Usage do
  @moduledoc "Per-agent provider usage recorded on each agent event."
  defstruct input_tokens: 0, output_tokens: 0, total_tokens: 0

  @type t :: %__MODULE__{
          input_tokens: non_neg_integer(),
          output_tokens: non_neg_integer(),
          total_tokens: non_neg_integer()
        }

  @spec add(t(), t()) :: t()
  def add(%__MODULE__{} = a, %__MODULE__{} = b) do
    %__MODULE__{
      input_tokens: a.input_tokens + b.input_tokens,
      output_tokens: a.output_tokens + b.output_tokens,
      total_tokens: a.total_tokens + b.total_tokens
    }
  end
end
