defmodule Workflow.Scheduler.Error do
  @moduledoc """
  Expected scheduler API failures.

  These errors are data, not exceptions: controllers can render them as stable
  JSON envelopes and direct callers can pattern-match on their codes.
  """

  @enforce_keys [:status, :code, :message]
  defstruct [:status, :code, :message, details: %{}]

  @type t :: %__MODULE__{
          status: pos_integer(),
          code: String.t(),
          message: String.t(),
          details: map()
        }

  @spec run_start_not_available() :: t()
  def run_start_not_available do
    %__MODULE__{
      status: 501,
      code: "scheduler.run_start_not_available",
      message: "Workflow run start is not available in this scheduler API slice."
    }
  end

  @spec malformed_json() :: t()
  def malformed_json do
    %__MODULE__{
      status: 400,
      code: "scheduler.malformed_json",
      message: "Malformed JSON request body."
    }
  end

  @spec not_found() :: t()
  def not_found do
    %__MODULE__{
      status: 404,
      code: "scheduler.not_found",
      message: "Scheduler API route not found."
    }
  end

  @spec unavailable(map()) :: t()
  def unavailable(checks) do
    %__MODULE__{
      status: 503,
      code: "scheduler.unavailable",
      message: "Scheduler runtime dependencies are unavailable.",
      details: %{checks: checks}
    }
  end
end
