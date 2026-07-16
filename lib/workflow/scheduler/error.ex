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

  @spec invalid_run_args(term()) :: t()
  def invalid_run_args({:too_large, actual_bytes, max_bytes}) do
    new(413, "scheduler.run.args_too_large", "Workflow arguments exceed the size limit.", %{
      field: "args",
      actual_bytes: actual_bytes,
      max_bytes: max_bytes
    })
  end

  def invalid_run_args({:schema, reason}) do
    new(422, "scheduler.run.args_schema_mismatch", "Workflow arguments do not match the declared inputs.", %{
      field: "args",
      reason: inspect(reason)
    })
  end

  def invalid_run_args(reason) do
    new(400, "scheduler.run.invalid_args", "Workflow arguments must be JSON data.", %{
      field: "args",
      reason: inspect(reason)
    })
  end

  @spec resume_args_immutable() :: t()
  def resume_args_immutable do
    new(409, "scheduler.run.args_immutable", "Workflow arguments cannot be changed during resume.", %{
      field: "args"
    })
  end

  @spec workflow_changed(String.t(), String.t(), String.t()) :: t()
  def workflow_changed(run_id, recorded, current) do
    new(409, "scheduler.run.workflow_changed", "The compiled workflow has changed since this run started.", %{
      run_id: run_id,
      recorded_tree_fingerprint: recorded,
      current_tree_fingerprint: current
    })
  end

  @spec run_args_mismatch(String.t(), String.t(), String.t()) :: t()
  def run_args_mismatch(run_id, recorded, supplied) do
    new(409, "scheduler.run.args_mismatch", "The supplied arguments differ from this run's immutable arguments.", %{
      run_id: run_id,
      recorded_args_digest: recorded,
      supplied_args_digest: supplied
    })
  end

  @spec invalid_workspace_root(term(), term()) :: t()
  def invalid_workspace_root(root, reason) do
    new(
      400,
      "scheduler.run.invalid_workspace_root",
      "Workspace root must be an absolute existing directory.",
      workspace_details("workspace_root", root, reason, "absolute_existing_directory")
    )
  end

  @spec invalid_workspace_script(term(), term()) :: t()
  def invalid_workspace_script(path, reason) do
    new(
      400,
      "scheduler.run.invalid_script_path",
      "Workflow script must resolve to an existing regular file.",
      workspace_details("script_path", path, reason, "existing_regular_file")
    )
  end

  @spec script_outside_workspace(String.t(), String.t()) :: t()
  def script_outside_workspace(script_path, workspace_root) do
    new(
      400,
      "scheduler.run.script_outside_workspace",
      "Workflow script must be contained by the workspace root.",
      %{script_path: script_path, workspace_root: workspace_root}
    )
  end

  @spec invalid_run_id() :: t()
  def invalid_run_id do
    new(400, "scheduler.run.invalid_run_id", "Run id must be route-safe and at most 128 bytes.", %{
      field: "run_id",
      expected: "route_safe_string_max_128_bytes",
      max_bytes: 128
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

  @spec run_capacity_exceeded(pos_integer()) :: t()
  def run_capacity_exceeded(max_active_runs) do
    new(
      503,
      "scheduler.run.capacity_exceeded",
      "The scheduler is already running the maximum number of workflows.",
      %{max_active_runs: max_active_runs}
    )
  end

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

  defp workspace_details(field, value, reason, expected) do
    maybe_put_value(%{field: field, expected: expected, reason: inspect(reason)}, value)
  end

  defp maybe_put_value(details, value) when is_binary(value), do: Map.put(details, :value, value)
  defp maybe_put_value(details, _value), do: details

  defp new(status, code, message, details \\ %{}),
    do: %__MODULE__{status: status, code: code, message: message, details: details}
end
