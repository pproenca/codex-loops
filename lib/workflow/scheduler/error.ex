defmodule Workflow.Scheduler.Error do
  @moduledoc """
  Expected scheduler API failures.

  These errors are data, not exceptions: controllers can render them as stable
  JSON envelopes and direct callers can pattern-match on their codes.
  """

  alias Workflow.Script.Error

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

  @spec invalid_provider([String.t()]) :: t()
  def invalid_provider(supported) do
    %__MODULE__{
      status: 400,
      code: "scheduler.run.invalid_provider",
      message: "Unsupported run provider.",
      details: %{field: "provider", supported: supported}
    }
  end

  @spec invalid_budget() :: t()
  def invalid_budget do
    %__MODULE__{
      status: 400,
      code: "scheduler.run.invalid_budget",
      message: "Run budget must be a non-negative integer.",
      details: %{field: "budget", expected: "non_negative_integer"}
    }
  end

  @spec invalid_run_id() :: t()
  def invalid_run_id do
    %__MODULE__{
      status: 400,
      code: "scheduler.run.invalid_run_id",
      message: "Run id must be a non-empty string.",
      details: %{field: "run_id", expected: "route_safe_non_empty_string"}
    }
  end

  @spec run_already_running(String.t() | nil) :: t()
  def run_already_running(run_id) do
    %__MODULE__{
      status: 409,
      code: "scheduler.run.already_running",
      message: "A workflow run with this id is already running.",
      details: %{run_id: run_id}
    }
  end

  @spec run_not_found(String.t()) :: t()
  def run_not_found(run_id) do
    %__MODULE__{
      status: 404,
      code: "scheduler.run.not_found",
      message: "Workflow run not found.",
      details: %{run_id: run_id}
    }
  end

  @spec run_start_failed(term()) :: t()
  def run_start_failed(reason) do
    %__MODULE__{
      status: 503,
      code: "scheduler.run.start_failed",
      message: "Workflow run could not be started.",
      details: %{reason: inspect(reason)}
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

  @spec workflow_validation(Error.t()) :: t()
  def workflow_validation(%Error{kind: :script_not_found} = error) do
    %__MODULE__{
      status: 404,
      code: "scheduler.validation.script_not_found",
      message: error.message,
      details: validation_details(error)
    }
  end

  def workflow_validation(%Error{} = error) do
    type = Atom.to_string(error.kind)

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

  defp validation_details(%Error{} = error) do
    error.details
    |> Map.put(:path, error.path)
    |> Map.put(:reason, error.message)
    |> Map.put(:type, error.kind)
  end
end
