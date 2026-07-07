defmodule Workflow.Scheduler.RunProjection do
  @moduledoc """
  Scheduler-owned read projection for a run.

  The projection is derived from `Workflow.Status`, which folds the journal, plus
  scheduler-owned runtime lease facts used only for lifecycle availability. API
  reads and LiveView renders use the same scheduler snapshot.
  """

  alias Workflow.Provider.Usage
  alias Workflow.Status

  @enforce_keys [
    :run_id,
    :state,
    :workflow_name,
    :tree_name,
    :phase,
    :logs,
    :agent_count,
    :event_count,
    :usage,
    :result,
    :failure,
    :lifecycle_action,
    :ui_path,
    :ui_url
  ]
  defstruct [
    :run_id,
    :state,
    :workflow_name,
    :tree_name,
    :phase,
    :logs,
    :agent_count,
    :event_count,
    :usage,
    :result,
    :failure,
    :lifecycle_action,
    :ui_path,
    :ui_url
  ]

  @type t :: %__MODULE__{
          run_id: String.t(),
          state: atom(),
          workflow_name: String.t() | nil,
          tree_name: String.t() | nil,
          phase: String.t() | nil,
          logs: [String.t()],
          agent_count: non_neg_integer(),
          event_count: non_neg_integer(),
          usage: Usage.t(),
          result: term(),
          failure: map() | nil,
          lifecycle_action: map(),
          ui_path: String.t(),
          ui_url: String.t()
        }

  @spec from_status(Status.t()) :: t()
  @spec from_status(Status.t(), keyword()) :: t()
  def from_status(%Status{} = status, opts \\ []) do
    ui_path = "/runs/#{status.run_id}"

    %__MODULE__{
      run_id: status.run_id,
      state: status.state,
      workflow_name: status.tree_name,
      tree_name: status.tree_name,
      phase: status.phase,
      logs: status.logs,
      agent_count: length(status.agents),
      event_count: status.event_count,
      usage: status.usage,
      result: status.result,
      failure: status.failure,
      lifecycle_action: lifecycle_action(status, opts),
      ui_path: ui_path,
      ui_url: ui_path
    }
  end

  @spec lifecycle_action(Status.t(), keyword()) :: map()
  def lifecycle_action(%Status{} = status, opts \\ []) do
    events = Keyword.get(opts, :events, [])
    running? = Keyword.get(opts, :running?, false)
    known? = known?(status, events, running?)

    cond do
      running? ->
        unavailable(:pause_unavailable, "Pause unavailable", "Pause is not implemented.")

      recoverable?(status, events, known?) ->
        %{
          action: :resume,
          label: "Resume",
          enabled: true,
          reason: "The writer is stopped before a terminal event.",
          method: "post",
          href: "/api/runs/#{status.run_id}/resume"
        }

      not known? ->
        unavailable(:run_unavailable, "Run unavailable", "No journaled run exists yet.")

      incomplete_without_script?(status, events) ->
        unavailable(
          :resume_unavailable,
          "Resume unavailable",
          "No journaled script path is available."
        )

      true ->
        unavailable(:none, "No lifecycle action", "Run is #{status.state}.")
    end
  end

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = projection) do
    %{
      run_id: projection.run_id,
      state: projection.state,
      workflow_name: projection.workflow_name,
      tree_name: projection.tree_name,
      phase: projection.phase,
      logs: projection.logs,
      agent_count: projection.agent_count,
      event_count: projection.event_count,
      usage: usage_map(projection.usage),
      result: jsonable(projection.result),
      failure: encode_failure(projection.failure),
      lifecycle_action: lifecycle_action_map(projection.lifecycle_action),
      ui_path: projection.ui_path,
      ui_url: projection.ui_url
    }
  end

  defp known?(%Status{event_count: event_count}, events, running?),
    do: running? or events != [] or event_count > 0

  defp recoverable?(%Status{state: :running}, events, true), do: journaled_script_path?(events)
  defp recoverable?(_status, _events, _known?), do: false

  defp incomplete_without_script?(%Status{state: :running}, events),
    do: not journaled_script_path?(events)

  defp incomplete_without_script?(_status, _events), do: false

  defp journaled_script_path?(events) do
    Enum.any?(events, fn
      %{type: :run_started, payload: %{script_path: path}} when is_binary(path) and path != "" ->
        true

      _event ->
        false
    end)
  end

  defp unavailable(action, label, reason) do
    %{
      action: action,
      label: label,
      enabled: false,
      reason: reason,
      method: nil,
      href: nil
    }
  end

  defp lifecycle_action_map(action) do
    %{
      action: action.action,
      label: action.label,
      enabled: action.enabled,
      reason: action.reason,
      method: action.method,
      href: action.href
    }
  end

  defp usage_map(%Usage{} = usage) do
    %{
      input_tokens: usage.input_tokens,
      output_tokens: usage.output_tokens,
      total_tokens: usage.total_tokens
    }
  end

  defp encode_failure(nil), do: nil

  defp encode_failure(%{address: address, attempts: attempts, reason: reason}) do
    %{
      address: address,
      attempts: attempts,
      reason: inspect(reason)
    }
  end

  defp jsonable(term) do
    case Jason.encode(term) do
      {:ok, _json} -> term
      {:error, _reason} -> inspect(term)
    end
  end
end
