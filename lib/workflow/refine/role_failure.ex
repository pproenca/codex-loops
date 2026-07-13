defmodule Workflow.Refine.RoleFailure do
  @moduledoc """
  A terminal failure of one refine role attempt.

  Journal payloads stay plain maps for the versioned storage boundary. `from_payload/1`
  restores the named runtime entity and supplies defaults for fields added to old
  journal entries.
  """

  alias Workflow.Provider.Activity
  alias Workflow.Provider.Usage

  @enforce_keys [
    :address,
    :role,
    :role_address,
    :round,
    :reviewer,
    :reviewer_index,
    :attempts,
    :reason,
    :detail,
    :usage,
    :activity
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          address: Workflow.Node.address(),
          role: :reviewer | :cold_read | :repair,
          role_address: Workflow.Node.address(),
          round: non_neg_integer() | nil,
          reviewer: atom() | nil,
          reviewer_index: non_neg_integer() | nil,
          attempts: pos_integer(),
          reason: term(),
          detail: term(),
          usage: Usage.t() | nil,
          activity: [Activity.t() | map()]
        }

  @spec from_payload(t() | map()) :: t()
  def from_payload(%__MODULE__{} = failure), do: failure

  def from_payload(
        %{address: address, role: role, role_address: role_address, attempts: attempts, reason: reason} = payload
      ) do
    %__MODULE__{
      address: address,
      role: role,
      role_address: role_address,
      round: Map.get(payload, :round),
      reviewer: Map.get(payload, :reviewer),
      reviewer_index: Map.get(payload, :reviewer_index),
      attempts: attempts,
      reason: reason,
      detail: Map.get(payload, :detail),
      usage: Map.get(payload, :usage),
      activity: Map.get(payload, :activity, [])
    }
  end

  @spec to_payload(t()) :: map()
  def to_payload(%__MODULE__{} = failure), do: Map.from_struct(failure)
end
