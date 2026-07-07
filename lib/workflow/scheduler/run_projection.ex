defmodule Workflow.Scheduler.RunProjection do
  @moduledoc """
  Scheduler-owned read projection for a run.

  The projection is derived from `Workflow.Status`, which folds the journal. It is
  deliberately independent of the live writer process so API reads and LiveView
  renders have the same source of truth.
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
          ui_path: String.t(),
          ui_url: String.t()
        }

  @spec from_status(Status.t()) :: t()
  def from_status(%Status{} = status) do
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
      ui_path: ui_path,
      ui_url: ui_path
    }
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
      ui_path: projection.ui_path,
      ui_url: projection.ui_url
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
