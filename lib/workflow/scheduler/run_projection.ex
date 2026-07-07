defmodule Workflow.Scheduler.RunProjection do
  @moduledoc """
  Scheduler-owned read projection for a run.

  The projection is derived from `Workflow.Status`, which folds the journal. It is
  deliberately independent of the live writer process so API reads and LiveView
  renders have the same source of truth.
  """

  alias Workflow.Provider.Usage
  alias Workflow.{RunInspector, Status}

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
    :inspector,
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
    :inspector,
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
          inspector: map(),
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
      inspector: inspector_from_status(status),
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
      inspector: projection.inspector,
      result: jsonable(projection.result),
      failure: encode_failure(projection.failure),
      ui_path: projection.ui_path,
      ui_url: projection.ui_url
    }
  end

  @spec inspector_from_status(Status.t()) :: map()
  def inspector_from_status(%Status{} = status) do
    inspector = RunInspector.from_status(status)

    %{
      run_id: inspector.run_id,
      phases: Enum.map(inspector.phases, &inspector_phase/1),
      agents: Enum.map(inspector.agents, &inspector_agent/1),
      rejected_attempts: Enum.map(inspector.rejected_attempts, &inspector_rejection/1),
      failed_rejected_attempts:
        Enum.map(inspector.failed_rejected_attempts, &inspector_rejection/1),
      failure: encode_failure(status.failure),
      usage: usage_map(status.usage),
      event_count: status.event_count
    }
  end

  defp inspector_phase(phase) do
    %{
      id: phase.id,
      name: phase.name,
      address: phase.address,
      agents: Enum.map(phase.agents, &inspector_agent/1)
    }
  end

  defp inspector_agent(agent) do
    %{
      id: agent.id,
      slug: agent.slug,
      address: agent.address,
      iteration: agent.iteration,
      prompt: text(agent.prompt),
      outcome: jsonable(agent.outcome),
      result: jsonable(agent.result),
      usage: usage_map(agent.usage),
      activity: Enum.map(agent.activity, &inspector_activity/1),
      phase_id: agent.phase_id,
      phase_name: agent.phase_name
    }
  end

  defp inspector_rejection(rejection) do
    %{
      id: rejection.id,
      address: rejection.address,
      iteration: rejection.iteration,
      attempt: rejection.attempt,
      prompt: text(rejection.prompt),
      output: jsonable(rejection.output),
      reason: inspect(rejection.reason),
      activity: Enum.map(rejection.activity, &inspector_activity/1),
      phase_id: rejection.phase_id,
      phase_name: rejection.phase_name
    }
  end

  defp inspector_activity(activity) do
    %{
      kind: Map.get(activity, :kind),
      label: Map.get(activity, :label),
      status: Map.get(activity, :status),
      summary: Map.get(activity, :summary)
    }
  end

  defp usage_map(%Usage{} = usage) do
    %{
      input_tokens: usage.input_tokens,
      output_tokens: usage.output_tokens,
      total_tokens: usage.total_tokens
    }
  end

  defp usage_map(_usage), do: usage_map(%Usage{})

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

  defp text(value) when is_binary(value), do: value
  defp text(value) when is_atom(value), do: Atom.to_string(value)
  defp text(value), do: inspect(value)
end
