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

  @spec invalid_provider([String.t()]) :: t()
  def invalid_provider(supported) do
    new(400, "scheduler.run.invalid_provider", "Unsupported run provider.", %{
      field: "provider",
      supported: supported
    })
  end

  @spec invalid_budget() :: t()
  def invalid_budget do
    new(400, "scheduler.run.invalid_budget", "Run budget must be a non-negative integer.", %{
      field: "budget",
      expected: "non_negative_integer"
    })
  end

  @spec invalid_run_id() :: t()
  def invalid_run_id do
    new(400, "scheduler.run.invalid_run_id", "Run id must be a non-empty string.", %{
      field: "run_id",
      expected: "route_safe_non_empty_string"
    })
  end

  @spec run_already_running(String.t() | nil) :: t()
  def run_already_running(run_id) do
    new(
      409,
      "scheduler.run.already_running",
      "A workflow run with this id is already running.",
      %{run_id: run_id}
    )
  end

  @spec run_not_found(String.t()) :: t()
  def run_not_found(run_id) do
    new(404, "scheduler.run.not_found", "Workflow run not found.", %{run_id: run_id})
  end

  @spec run_start_failed(term()) :: t()
  def run_start_failed(_reason), do: new(503, "scheduler.run.start_failed", "Workflow run could not be started.")

  @spec missing_script_path() :: t()
  def missing_script_path do
    new(400, "scheduler.validation.missing_script_path", "Missing workflow script path.", %{
      field: "script_path"
    })
  end

  @spec workflow_validation(Error.t()) :: t()
  def workflow_validation(%Error{kind: :script_not_found} = error) do
    new(
      404,
      "scheduler.validation.script_not_found",
      error.message,
      validation_details(error)
    )
  end

  def workflow_validation(%Error{} = error) do
    type = Atom.to_string(error.kind)

    new(
      422,
      "scheduler.validation.#{type}",
      "Workflow script failed validation.",
      validation_details(error)
    )
  end

  @spec malformed_json() :: t()
  def malformed_json, do: new(400, "scheduler.malformed_json", "Malformed JSON request body.")

  @spec unsupported_media_type(String.t() | nil) :: t()
  def unsupported_media_type(media_type) do
    new(
      415,
      "scheduler.unsupported_media_type",
      "Scheduler API mutation requests require an application/json body.",
      %{expected: "application/json", received: media_type}
    )
  end

  @spec request_too_large(pos_integer()) :: t()
  def request_too_large(max_bytes) do
    new(
      413,
      "scheduler.request_too_large",
      "Scheduler API request body is too large.",
      %{max_bytes: max_bytes}
    )
  end

  @spec not_found() :: t()
  def not_found, do: new(404, "scheduler.not_found", "Scheduler API route not found.")

  @spec unavailable(map()) :: t()
  def unavailable(checks) do
    new(
      503,
      "scheduler.unavailable",
      "Scheduler runtime dependencies are unavailable.",
      %{checks: checks}
    )
  end

  defp validation_details(%Error{} = error) do
    Map.merge(error.details, %{path: error.path, reason: error.message, type: error.kind})
  end

  defp new(status, code, message, details \\ %{}),
    do: %__MODULE__{status: status, code: code, message: message, details: details}
end
