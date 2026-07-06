defmodule Workflow.Provider do
  @moduledoc """
  The contract an agent backend must satisfy. Results are **opaque** in this slice:
  no schema, no retry. Every call reports `Usage` so the budget ledger can fold
  over agent events in a later slice.
  """

  @type result :: term()

  @callback run_agent(prompt :: String.t(), opts :: term()) ::
              {:ok, result(), Workflow.Provider.Usage.t()}
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
