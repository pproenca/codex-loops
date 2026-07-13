defmodule Workflow.Provider do
  @moduledoc """
  The contract an agent backend must satisfy. `schema` is the raw JSON-schema map
  the caller wants the output to conform to, or `nil` for a schemaless turn — a
  real backend uses it to request structured output; the runner independently
  validates and, on failure, retries or fails the node (the provider never sees
  retry policy). Every call reports `Usage` so the budget ledger can fold over
  agent events.

  ## Request identity and crash semantics

  Every call carries the paid effect's `Workflow.IdempotencyKey` — `(run_id,
  node_path, iteration)` refined by the `attempt` (retry) index, so each distinct
  paid call — including each fail-closed retry — has a distinct, stable identity.
  The writer records that identity in an `agent_started` event before calling the
  backend and reuses a settled result from the journal without calling again.

  There is no portable way to make a third-party model call transactional with
  the local SQLite commit. If the writer dies after `agent_started` but before a
  matching settlement, the scheduler records `outcome_unknown` and never
  redelivers that attempt. This is deliberately at-most-once: it prevents a hidden
  double charge, while acknowledging that a result can be lost in the crash
  window. Providers may use the key for tracing or backend deduplication, but
  scheduler correctness does not assume that they do.
  """

  alias Workflow.Provider.Activity
  alias Workflow.Provider.Usage

  @type result :: term()
  @type failure_kind :: :quota_exceeded | :model_limit | :timeout | :unavailable | :backend
  @type failure_detail ::
          nil
          | boolean()
          | integer()
          | String.t()
          | [failure_detail()]
          | %{optional(String.t()) => failure_detail()}

  @type activity :: [Activity.t()]

  @callback run_agent(
              prompt :: String.t(),
              schema :: map() | nil,
              key :: Workflow.IdempotencyKey.t(),
              opts :: term()
            ) ::
              {:ok, result(), Usage.t()}
              | {:ok, result(), Usage.t(), activity()}
              | {:error, {:provider_failure, failure_kind(), failure_detail(), Usage.t() | map() | nil, activity()}}

  @typedoc "A resolved backend: the provider module plus its opaque per-run opts."
  @type t :: {module(), term()}

  @callback validate_config(opts :: term()) :: :ok | {:error, term()}
  @optional_callbacks validate_config: 1

  @spec resolve(t() | nil | term()) ::
          {:ok, t()} | {:error, {:usage, :provider} | {:provider_config, term()}}
  def resolve(nil), do: {:error, {:usage, :provider}}

  def resolve({module, opts}) when is_atom(module) do
    with :ok <- ensure_provider(module),
         :ok <- validate_provider_config(module, opts) do
      {:ok, {module, opts}}
    end
  end

  def resolve(other), do: {:error, {:provider_config, {:not_a_provider, other}}}

  @doc """
  Resolve a backend name (the `--provider` flag) into a `{module, opts}` port the
  interpreter can drive. This is the whole of provider selection: swapping `:mock`
  for `:codex` changes only which module the writer calls — never any core, writer,
  or fold code — so the two backends are interchangeable behind one port.
  """
  @spec select(:mock | :codex, keyword()) :: t()
  def select(:mock, opts), do: {Workflow.Provider.Mock, opts}
  def select(:codex, opts), do: {Workflow.Provider.Codex, opts}

  defp ensure_provider(module) do
    with {:module, ^module} <- Code.ensure_loaded(module),
         true <- function_exported?(module, :run_agent, 4) do
      :ok
    else
      _not_a_provider -> {:error, {:provider_config, {:not_a_provider, module}}}
    end
  end

  defp validate_provider_config(module, opts) do
    if function_exported?(module, :validate_config, 1) do
      case module.validate_config(opts) do
        :ok -> :ok
        {:error, reason} -> {:error, {:provider_config, reason}}
      end
    else
      :ok
    end
  end
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
