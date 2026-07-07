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

  @spec missing_script_path() :: t()
  def missing_script_path do
    %__MODULE__{
      status: 400,
      code: "scheduler.validation.missing_script_path",
      message: "Missing workflow script path.",
      details: %{field: "script_path"}
    }
  end

  @spec workflow_validation(Workflow.Script.Error.t()) :: t()
  def workflow_validation(%Workflow.Script.Error{kind: :script_not_found} = error) do
    %__MODULE__{
      status: 404,
      code: "scheduler.validation.script_not_found",
      message: error.message,
      details: validation_details(error)
    }
  end

  def workflow_validation(%Workflow.Script.Error{} = error) do
    type = error.kind |> Atom.to_string()

    %__MODULE__{
      status: 422,
      code: "scheduler.validation.#{type}",
      message: "Workflow script failed validation.",
      details: validation_details(error)
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

  defp validation_details(%Workflow.Script.Error{} = error) do
    error.details
    |> Map.put(:path, error.path)
    |> Map.put(:reason, error.message)
    |> Map.put(:type, error.kind)
  end
end
