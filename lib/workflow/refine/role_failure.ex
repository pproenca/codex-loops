defmodule Workflow.Refine.RoleFailure do
  @moduledoc """
  A terminal failure of one refine role attempt.

  Journal payloads stay plain maps for the versioned storage boundary. `from_payload/1`
  restores the named runtime entity and supplies defaults for fields added to old
  journal entries.
  """

  alias Workflow.JSONValue
  alias Workflow.Provider.Activity
  alias Workflow.Provider.Usage

  @type reason ::
          {:provider_failure, atom(), term()}
          | {:malformed_output, term()}
          | {:reviewer_timeout, non_neg_integer()}
          | {:cold_read_timeout, non_neg_integer()}
          | {:reviewer_crashed, term()}
          | {:cold_read_crashed, term()}
          | {:repair_failed, term()}

  @type detail_encoder :: (term() -> term())

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
          reason: reason(),
          detail: term(),
          usage: Usage.t() | nil,
          activity: [Activity.t()]
        }

  @spec from_payload(map()) :: t()
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
      activity: payload |> Map.get(:activity, []) |> Activity.normalize_all!()
    }
  end

  @spec to_payload(t()) :: map()
  def to_payload(%__MODULE__{} = failure) do
    failure
    |> Map.from_struct()
    |> Map.update!(:activity, &Enum.map(&1, fn activity -> Activity.to_payload(activity) end))
  end

  @doc "Return the stable public code for a refine role failure reason."
  @spec reason_code(term()) :: String.t()
  def reason_code(reason) do
    {code, _payload} = normalize_reason(reason)
    code
  end

  @doc "Build the public reason object while preserving each projection's detail encoding."
  @spec reason_map(term(), keyword(detail_encoder())) :: map()
  def reason_map(reason, encoders) when is_list(encoders) do
    provider_detail = Keyword.fetch!(encoders, :provider_detail)
    diagnostic_detail = Keyword.fetch!(encoders, :diagnostic_detail)
    {code, payload} = normalize_reason(reason)

    put_reason_payload(%{"code" => code}, payload, provider_detail, diagnostic_detail)
  end

  defp normalize_reason({:provider_failure, kind, detail}), do: {"provider_failure", {:provider, kind, detail}}

  defp normalize_reason({:malformed_output, detail}), do: {"malformed_output", {:diagnostic, detail}}
  defp normalize_reason({:reviewer_timeout, timeout_ms}), do: {"reviewer_timeout", {:timeout, timeout_ms}}
  defp normalize_reason({:cold_read_timeout, timeout_ms}), do: {"cold_read_timeout", {:timeout, timeout_ms}}
  defp normalize_reason({:reviewer_crashed, detail}), do: {"reviewer_crashed", {:diagnostic, detail}}
  defp normalize_reason({:cold_read_crashed, detail}), do: {"cold_read_crashed", {:diagnostic, detail}}
  defp normalize_reason({:repair_failed, detail}), do: {"repair_failed", {:diagnostic, detail}}
  defp normalize_reason(reason) when is_atom(reason), do: {Atom.to_string(reason), :none}
  defp normalize_reason(reason), do: {"unknown", {:diagnostic, reason}}

  defp put_reason_payload(map, :none, _provider_detail, _diagnostic_detail), do: map

  defp put_reason_payload(map, {:provider, kind, detail}, provider_detail, _diagnostic_detail) do
    Map.merge(map, %{"kind" => JSONValue.stringify(kind), "detail" => provider_detail.(detail)})
  end

  defp put_reason_payload(map, {:timeout, timeout_ms}, _provider_detail, _diagnostic_detail),
    do: Map.put(map, "timeoutMs", timeout_ms)

  defp put_reason_payload(map, {:diagnostic, detail}, _provider_detail, diagnostic_detail),
    do: Map.put(map, "detail", diagnostic_detail.(detail))
end
