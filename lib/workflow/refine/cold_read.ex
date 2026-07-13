defmodule Workflow.Refine.ColdRead do
  @moduledoc "The tagged result of the optional post-refine cold-read role."

  alias Workflow.Refine.OpenFinding
  alias Workflow.Refine.ReviewerDecision
  alias Workflow.Refine.RoleFailure

  @enforce_keys [
    :state,
    :open_findings,
    :reviewer_decision,
    :report_snippets,
    :role_failure,
    :repair
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          state: :completed | :failed,
          open_findings: [OpenFinding.t()],
          reviewer_decision: ReviewerDecision.t() | nil,
          report_snippets: [String.t()],
          role_failure: RoleFailure.t() | nil,
          repair: :not_run | :completed
        }

  @spec completed([OpenFinding.t()], ReviewerDecision.t(), [String.t()]) :: t()
  def completed(open_findings, %ReviewerDecision{} = reviewer_decision, report_snippets) do
    %__MODULE__{
      state: :completed,
      open_findings: open_findings,
      reviewer_decision: reviewer_decision,
      report_snippets: report_snippets,
      role_failure: nil,
      repair: :not_run
    }
  end

  @spec failed(RoleFailure.t()) :: t()
  def failed(%RoleFailure{} = role_failure) do
    %__MODULE__{
      state: :failed,
      open_findings: [],
      reviewer_decision: nil,
      report_snippets: [],
      role_failure: role_failure,
      repair: :not_run
    }
  end

  @spec repaired(t()) :: t()
  def repaired(%__MODULE__{} = cold_read), do: %{cold_read | repair: :completed}

  @spec repaired?(t()) :: boolean()
  def repaired?(%__MODULE__{repair: :completed}), do: true
  def repaired?(%__MODULE__{repair: :not_run}), do: false

  @spec from_payload(map()) :: t()
  def from_payload(%{state: :completed} = payload) do
    payload
    |> Map.get(:open_findings, [])
    |> Enum.map(&OpenFinding.from_payload/1)
    |> completed(
      payload |> Map.fetch!(:reviewer_decision) |> ReviewerDecision.from_payload(),
      Map.get(payload, :report_snippets, [])
    )
    |> put_repair(payload)
  end

  def from_payload(%{state: :failed} = payload) do
    payload
    |> Map.fetch!(:role_failure)
    |> RoleFailure.from_payload()
    |> failed()
    |> put_repair(payload)
  end

  @spec to_payload(t()) :: map()
  def to_payload(%__MODULE__{state: :completed} = cold_read) do
    %{
      state: :completed,
      open_findings: Enum.map(cold_read.open_findings, &OpenFinding.to_payload/1),
      reviewer_decision: ReviewerDecision.to_payload(cold_read.reviewer_decision),
      report_snippets: cold_read.report_snippets,
      repair: cold_read.repair
    }
  end

  def to_payload(%__MODULE__{state: :failed} = cold_read) do
    %{
      state: :failed,
      role_failure: RoleFailure.to_payload(cold_read.role_failure),
      repair: cold_read.repair
    }
  end

  defp put_repair(cold_read, %{repair: :completed}), do: repaired(cold_read)
  defp put_repair(cold_read, %{repair: :not_run}), do: cold_read
  defp put_repair(cold_read, %{repaired: true}), do: repaired(cold_read)
  defp put_repair(cold_read, _payload), do: cold_read
end
