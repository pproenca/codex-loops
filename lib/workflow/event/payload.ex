defprotocol Workflow.Event.Payload do
  @moduledoc "The closed behavior shared by durable event payload variants."

  @type event_type ::
          :run_started
          | :phase_entered
          | :log_emitted
          | :agent_started
          | :agent_activity
          | :agent_attempt_rejected
          | :agent_committed
          | :agent_failed
          | :parallel_started
          | :parallel_completed
          | :pipeline_started
          | :pipeline_completed
          | :fanout_started
          | :fanout_completed
          | :fanout_failed
          | :fan_out_started
          | :fan_out_completed
          | :iteration_started
          | :loop_decision
          | :loop_completed
          | :loop_exhausted
          | :accumulate
          | :verify_started
          | :verify_settled
          | :refine_started
          | :refine_round_started
          | :refine_round_decision
          | :refine_role_failed
          | :refine_completed
          | :refine_non_converged
          | :refine_gate_evaluated
          | :refine_input_invalid
          | :judge_started
          | :judge_settled
          | :run_completed
          | :run_failed

  @spec type(t()) :: event_type()
  def type(payload)

  @spec to_map(t()) :: map()
  def to_map(payload)
end

defmodule Workflow.Event.Payload.RunStarted do
  @moduledoc false
  @enforce_keys [:tree_name, :tree_version, :node_count, :budget, :script_path]
  defstruct @enforce_keys ++ [workspace_root: nil]
  @type t :: %__MODULE__{}
end

defmodule Workflow.Event.Payload.PhaseEntered do
  @moduledoc false
  @enforce_keys [:address, :name]
  defstruct @enforce_keys
  @type t :: %__MODULE__{}
end

defmodule Workflow.Event.Payload.LogEmitted do
  @moduledoc false
  @enforce_keys [:address, :message]
  defstruct @enforce_keys
  @type t :: %__MODULE__{}
end

defmodule Workflow.Event.Payload.AgentStarted do
  @moduledoc false
  @enforce_keys [:address, :iteration, :attempt, :idempotency_key, :label, :prompt]
  defstruct @enforce_keys
  @type t :: %__MODULE__{}
end

defmodule Workflow.Event.Payload.AgentActivity do
  @moduledoc false
  alias Workflow.Provider.Activity

  @enforce_keys [:address, :iteration, :attempt, :activity_index, :label, :prompt, :entry]
  defstruct @enforce_keys
  @type t :: %__MODULE__{entry: Activity.t()}

  def to_map(%__MODULE__{} = payload) do
    payload
    |> Map.from_struct()
    |> Map.update!(:entry, &Activity.to_payload/1)
  end
end

defmodule Workflow.Event.Payload.AgentAttemptRejected do
  @moduledoc false
  alias Workflow.Provider.Activity

  @enforce_keys [:address, :iteration, :attempt, :label, :prompt, :output, :reason, :usage, :activity]
  defstruct @enforce_keys
  @type t :: %__MODULE__{activity: [Activity.t()]}

  def to_map(%__MODULE__{} = payload), do: activity_payload(payload)

  defp activity_payload(payload) do
    payload
    |> Map.from_struct()
    |> Map.update!(:activity, &Enum.map(&1, fn activity -> Activity.to_payload(activity) end))
  end
end

defmodule Workflow.Event.Payload.AgentCommitted do
  @moduledoc false
  alias Workflow.Provider.Activity

  @enforce_keys [:address, :iteration, :idempotency_key, :label, :prompt, :result, :usage, :activity]
  defstruct @enforce_keys
  @type t :: %__MODULE__{activity: [Activity.t()]}

  def to_map(%__MODULE__{} = payload) do
    payload
    |> Map.from_struct()
    |> Map.update!(:activity, &Enum.map(&1, fn activity -> Activity.to_payload(activity) end))
  end
end

defmodule Workflow.Event.Payload.AgentFailed do
  @moduledoc false
  alias Workflow.Provider.Activity

  @enforce_keys [:address, :iteration, :attempts, :reason, :usage, :activity]
  defstruct @enforce_keys
  @type t :: %__MODULE__{activity: [Activity.t()]}

  def to_map(%__MODULE__{} = payload) do
    payload
    |> Map.from_struct()
    |> Map.update!(:activity, &Enum.map(&1, fn activity -> Activity.to_payload(activity) end))
  end
end

defmodule Workflow.Event.Payload.ParallelStarted do
  @moduledoc false
  @enforce_keys [:address, :branch_count]
  defstruct @enforce_keys
  @type t :: %__MODULE__{}
end

defmodule Workflow.Event.Payload.ParallelCompleted do
  @moduledoc false
  @enforce_keys [:address]
  defstruct @enforce_keys
  @type t :: %__MODULE__{}
end

defmodule Workflow.Event.Payload.PipelineStarted do
  @moduledoc false
  @enforce_keys [:address, :items, :item_count, :stage_count]
  defstruct @enforce_keys
  @type t :: %__MODULE__{}
end

defmodule Workflow.Event.Payload.PipelineCompleted do
  @moduledoc false
  @enforce_keys [:address]
  defstruct @enforce_keys
  @type t :: %__MODULE__{}
end

defmodule Workflow.Event.Payload.FanoutStarted do
  @moduledoc false
  @enforce_keys [:address, :iteration, :width_expr, :width, :bind]
  defstruct @enforce_keys
  @type t :: %__MODULE__{}
end

defmodule Workflow.Event.Payload.FanoutCompleted do
  @moduledoc false
  @enforce_keys [:address, :iteration]
  defstruct @enforce_keys
  @type t :: %__MODULE__{}
end

defmodule Workflow.Event.Payload.FanoutFailed do
  @moduledoc false
  @enforce_keys [:address, :iteration, :reason]
  defstruct @enforce_keys
  @type t :: %__MODULE__{}
end

defmodule Workflow.Event.Payload.LegacyFanOutStarted do
  @moduledoc false
  @enforce_keys [:address, :per, :width]
  defstruct @enforce_keys
  @type t :: %__MODULE__{}
end

defmodule Workflow.Event.Payload.LegacyFanOutCompleted do
  @moduledoc false
  @enforce_keys [:address]
  defstruct @enforce_keys
  @type t :: %__MODULE__{}
end

defmodule Workflow.Event.Payload.IterationStarted do
  @moduledoc false
  @enforce_keys [:address, :iteration]
  defstruct @enforce_keys
  @type t :: %__MODULE__{}
end

defmodule Workflow.Event.Payload.LoopDecision do
  @moduledoc false
  @enforce_keys [:address, :iteration, :decision, :predicate_result, :exhausted, :source_address]
  defstruct @enforce_keys
  @type t :: %__MODULE__{}
end

defmodule Workflow.Event.Payload.LoopCompleted do
  @moduledoc false
  @enforce_keys [:address, :iterations, :exhausted, :reason]
  defstruct @enforce_keys
  @type t :: %__MODULE__{}
end

defmodule Workflow.Event.Payload.LoopExhausted do
  @moduledoc false
  @enforce_keys [:address, :iterations, :reason]
  defstruct @enforce_keys
  @type t :: %__MODULE__{}
end

defmodule Workflow.Event.Payload.Accumulate do
  @moduledoc false
  @enforce_keys [:address, :into, :iteration, :seen_by, :added, :size]
  defstruct @enforce_keys
  @type t :: %__MODULE__{}
end

defmodule Workflow.Event.Payload.VerifyStarted do
  @moduledoc false
  @enforce_keys [:address, :mode, :voter_count, :threshold]
  defstruct @enforce_keys
  @type t :: %__MODULE__{}
end

defmodule Workflow.Event.Payload.VerifySettled do
  @moduledoc false
  @enforce_keys [:address, :confirmations, :total, :threshold, :survived]
  defstruct @enforce_keys
  @type t :: %__MODULE__{}
end

defmodule Workflow.Event.Payload.RefineStarted do
  @moduledoc false
  alias Workflow.Node.Agent
  alias Workflow.Node.Refine.ColdReadGate
  alias Workflow.Node.Refine.Gates
  alias Workflow.Node.Refine.HaltGate
  alias Workflow.Node.Refine.RepairGate
  alias Workflow.Refine.Reviewer

  @enforce_keys [
    :address,
    :input,
    :max_rounds,
    :until,
    :on_non_convergence,
    :max_concurrency,
    :reviewer_timeout_ms,
    :reviewers,
    :reviser,
    :gates,
    :artifact_schema_version,
    :review_schema_version,
    :review_adapter_versions
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          input:
            {:producer, Agent.t()}
            | {:binding, atom(), Workflow.Node.binding_ref()},
          reviewers: [Reviewer.t()],
          reviser: Agent.t(),
          gates: Gates.t()
        }

  def to_map(%__MODULE__{} = payload) do
    payload
    |> Map.from_struct()
    |> Map.put(:input, input_descriptor(payload.input))
    |> Map.put(:reviewers, Enum.map(payload.reviewers, &reviewer_descriptor/1))
    |> Map.put(:reviser, agent_descriptor(payload.reviser))
    |> Map.put(:gates, gate_descriptors(payload.gates))
  end

  defp input_descriptor({:producer, %Agent{} = agent}), do: agent |> agent_descriptor() |> Map.put(:kind, :producer)

  defp input_descriptor({:binding, name, ref}), do: %{kind: :binding, name: name, ref: ref}

  defp reviewer_descriptor(%Reviewer{index: index, name: name, adapter: adapter, agent: agent}) do
    agent
    |> agent_descriptor()
    |> Map.merge(%{index: index, name: name, adapter: adapter})
  end

  defp agent_descriptor(%Agent{} = agent) do
    %{address: agent.address, prompt: agent.prompt, retries: agent.retries, label: agent.label}
  end

  defp gate_descriptors(%Gates{} = gates) do
    Map.reject(
      %{
        cold_read: cold_read_gate_descriptor(gates.cold_read),
        repair: repair_gate_descriptor(gates.repair),
        halt: halt_gate_descriptor(gates.halt)
      },
      fn {_name, gate} -> is_nil(gate) end
    )
  end

  defp cold_read_gate_descriptor(nil), do: nil

  defp cold_read_gate_descriptor(%ColdReadGate{predicate: predicate, reviewer: reviewer}) do
    %{predicate: predicate, descriptor: reviewer_descriptor(reviewer)}
  end

  defp repair_gate_descriptor(nil), do: nil

  defp repair_gate_descriptor(%RepairGate{predicate: predicate, agent: agent}) do
    %{predicate: predicate, descriptor: agent_descriptor(agent)}
  end

  defp halt_gate_descriptor(nil), do: nil
  defp halt_gate_descriptor(%HaltGate{predicate: predicate}), do: %{predicate: predicate}
end

defmodule Workflow.Event.Payload.RefineRoundStarted do
  @moduledoc false
  @enforce_keys [:address, :round, :artifact]
  defstruct @enforce_keys
  @type t :: %__MODULE__{}
end

defmodule Workflow.Event.Payload.RefineRoundDecision do
  @moduledoc false
  alias Workflow.Refine.OpenFinding
  alias Workflow.Refine.ReviewerDecision
  alias Workflow.Refine.RoleFailure

  @enforce_keys [
    :address,
    :round,
    :consensus,
    :approval_count,
    :total,
    :reviewer_decisions,
    :artifact,
    :open_findings,
    :role_failures,
    :failed_reviewers,
    :report_snippets
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          reviewer_decisions: [ReviewerDecision.t()],
          open_findings: [OpenFinding.t()],
          role_failures: [RoleFailure.t()]
        }

  def to_map(%__MODULE__{} = payload) do
    payload
    |> Map.from_struct()
    |> Map.update!(:reviewer_decisions, &Enum.map(&1, fn value -> ReviewerDecision.to_payload(value) end))
    |> Map.update!(:open_findings, &Enum.map(&1, fn value -> OpenFinding.to_payload(value) end))
    |> Map.update!(:role_failures, &Enum.map(&1, fn value -> RoleFailure.to_payload(value) end))
  end

  def decision(%__MODULE__{} = payload) do
    %Workflow.Refine.RoundDecision{
      consensus: payload.consensus,
      approval_count: payload.approval_count,
      total: payload.total,
      reviewer_decisions: payload.reviewer_decisions,
      artifact: payload.artifact,
      open_findings: payload.open_findings,
      role_failures: payload.role_failures,
      failed_reviewers: payload.failed_reviewers,
      report_snippets: payload.report_snippets
    }
  end
end

defmodule Workflow.Event.Payload.RefineRoleFailed do
  @moduledoc false
  alias Workflow.Provider.Activity

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
  @type t :: %__MODULE__{activity: [Activity.t()]}

  def to_map(%__MODULE__{} = payload) do
    payload
    |> Map.from_struct()
    |> Map.update!(:activity, &Enum.map(&1, fn activity -> Activity.to_payload(activity) end))
  end

  def role_failure(%__MODULE__{} = payload) do
    %Workflow.Refine.RoleFailure{
      address: payload.address,
      role: payload.role,
      role_address: payload.role_address,
      round: payload.round,
      reviewer: payload.reviewer,
      reviewer_index: payload.reviewer_index,
      attempts: payload.attempts,
      reason: payload.reason,
      detail: payload.detail,
      usage: payload.usage,
      activity: payload.activity
    }
  end
end

defmodule Workflow.Event.Payload.RefineCompleted do
  @moduledoc false
  alias Workflow.Event.Payload.RefineTerminal

  @enforce_keys [
    :address,
    :converged,
    :final_round,
    :rounds,
    :artifact,
    :open_findings,
    :role_failures,
    :failed_reviewers,
    :reviewer_decisions,
    :report_snippets,
    :cold_read
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          open_findings: [Workflow.Refine.OpenFinding.t()],
          role_failures: [Workflow.Refine.RoleFailure.t()],
          reviewer_decisions: [Workflow.Refine.ReviewerDecision.t()],
          cold_read: Workflow.Refine.ColdRead.t() | nil
        }

  def to_map(%__MODULE__{} = payload), do: RefineTerminal.to_map(payload)
end

defmodule Workflow.Event.Payload.RefineNonConverged do
  @moduledoc false
  alias Workflow.Event.Payload.RefineTerminal

  @enforce_keys [
    :address,
    :converged,
    :final_round,
    :rounds,
    :artifact,
    :open_findings,
    :role_failures,
    :failed_reviewers,
    :reviewer_decisions,
    :report_snippets,
    :cold_read,
    :reason
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          open_findings: [Workflow.Refine.OpenFinding.t()],
          role_failures: [Workflow.Refine.RoleFailure.t()],
          reviewer_decisions: [Workflow.Refine.ReviewerDecision.t()],
          cold_read: Workflow.Refine.ColdRead.t() | nil
        }

  def to_map(%__MODULE__{} = payload), do: RefineTerminal.to_map(payload)
end

defmodule Workflow.Event.Payload.RefineTerminal do
  @moduledoc false
  alias Workflow.Refine.ColdRead
  alias Workflow.Refine.OpenFinding
  alias Workflow.Refine.ReviewerDecision
  alias Workflow.Refine.RoleFailure

  def to_map(payload) do
    payload
    |> Map.from_struct()
    |> Map.update!(:open_findings, &Enum.map(&1, fn value -> OpenFinding.to_payload(value) end))
    |> Map.update!(:role_failures, &Enum.map(&1, fn value -> RoleFailure.to_payload(value) end))
    |> Map.update!(:reviewer_decisions, &Enum.map(&1, fn value -> ReviewerDecision.to_payload(value) end))
    |> Map.update!(:cold_read, &cold_read_payload/1)
  end

  defp cold_read_payload(nil), do: nil
  defp cold_read_payload(cold_read), do: ColdRead.to_payload(cold_read)
end

defmodule Workflow.Event.Payload.RefineGateEvaluated do
  @moduledoc false
  @enforce_keys [:address, :gate, :predicate, :result, :input_round, :input_refs]
  defstruct @enforce_keys
  @type t :: %__MODULE__{}
end

defmodule Workflow.Event.Payload.RefineInputInvalid do
  @moduledoc false
  @enforce_keys [:address, :input, :reason]
  defstruct @enforce_keys
  @type t :: %__MODULE__{}
end

defmodule Workflow.Event.Payload.JudgeStarted do
  @moduledoc false
  @enforce_keys [:address, :candidates, :criteria]
  defstruct @enforce_keys
  @type t :: %__MODULE__{}
end

defmodule Workflow.Event.Payload.JudgeSettled do
  @moduledoc false
  @enforce_keys [:address, :scores, :pick, :winner]
  defstruct @enforce_keys
  @type t :: %__MODULE__{}
end

defmodule Workflow.Event.Payload.RunCompleted do
  @moduledoc false
  @enforce_keys [:value]
  defstruct @enforce_keys
  @type t :: %__MODULE__{}
end

defmodule Workflow.Event.Payload.RunFailed do
  @moduledoc false
  @enforce_keys [:reason]
  defstruct @enforce_keys
  @type t :: %__MODULE__{reason: term() | {:outcome_unknown, Workflow.IdempotencyKey.t()}}

  def to_map(%__MODULE__{reason: {:outcome_unknown, %Workflow.IdempotencyKey{} = key}} = payload) do
    payload
    |> Map.from_struct()
    |> Map.put(:reason, {:outcome_unknown, Workflow.IdempotencyKey.attempt_map(key)})
  end

  def to_map(%__MODULE__{} = payload), do: Map.from_struct(payload)
end

defimpl Workflow.Event.Payload, for: Workflow.Event.Payload.RunStarted do
  def type(_payload), do: :run_started
  def to_map(payload), do: Map.from_struct(payload)
end

defimpl Workflow.Event.Payload, for: Workflow.Event.Payload.PhaseEntered do
  def type(_payload), do: :phase_entered
  def to_map(payload), do: Map.from_struct(payload)
end

defimpl Workflow.Event.Payload, for: Workflow.Event.Payload.LogEmitted do
  def type(_payload), do: :log_emitted
  def to_map(payload), do: Map.from_struct(payload)
end

defimpl Workflow.Event.Payload, for: Workflow.Event.Payload.AgentStarted do
  def type(_payload), do: :agent_started
  def to_map(payload), do: Map.from_struct(payload)
end

defimpl Workflow.Event.Payload, for: Workflow.Event.Payload.AgentActivity do
  def type(_payload), do: :agent_activity
  def to_map(payload), do: Workflow.Event.Payload.AgentActivity.to_map(payload)
end

defimpl Workflow.Event.Payload, for: Workflow.Event.Payload.AgentAttemptRejected do
  def type(_payload), do: :agent_attempt_rejected
  def to_map(payload), do: Workflow.Event.Payload.AgentAttemptRejected.to_map(payload)
end

defimpl Workflow.Event.Payload, for: Workflow.Event.Payload.AgentCommitted do
  def type(_payload), do: :agent_committed
  def to_map(payload), do: Workflow.Event.Payload.AgentCommitted.to_map(payload)
end

defimpl Workflow.Event.Payload, for: Workflow.Event.Payload.AgentFailed do
  def type(_payload), do: :agent_failed
  def to_map(payload), do: Workflow.Event.Payload.AgentFailed.to_map(payload)
end

defimpl Workflow.Event.Payload, for: Workflow.Event.Payload.ParallelStarted do
  def type(_payload), do: :parallel_started
  def to_map(payload), do: Map.from_struct(payload)
end

defimpl Workflow.Event.Payload, for: Workflow.Event.Payload.ParallelCompleted do
  def type(_payload), do: :parallel_completed
  def to_map(payload), do: Map.from_struct(payload)
end

defimpl Workflow.Event.Payload, for: Workflow.Event.Payload.PipelineStarted do
  def type(_payload), do: :pipeline_started
  def to_map(payload), do: Map.from_struct(payload)
end

defimpl Workflow.Event.Payload, for: Workflow.Event.Payload.PipelineCompleted do
  def type(_payload), do: :pipeline_completed
  def to_map(payload), do: Map.from_struct(payload)
end

defimpl Workflow.Event.Payload, for: Workflow.Event.Payload.FanoutStarted do
  def type(_payload), do: :fanout_started
  def to_map(payload), do: Map.from_struct(payload)
end

defimpl Workflow.Event.Payload, for: Workflow.Event.Payload.FanoutCompleted do
  def type(_payload), do: :fanout_completed
  def to_map(payload), do: Map.from_struct(payload)
end

defimpl Workflow.Event.Payload, for: Workflow.Event.Payload.FanoutFailed do
  def type(_payload), do: :fanout_failed
  def to_map(payload), do: Map.from_struct(payload)
end

defimpl Workflow.Event.Payload, for: Workflow.Event.Payload.LegacyFanOutStarted do
  def type(_payload), do: :fan_out_started
  def to_map(payload), do: Map.from_struct(payload)
end

defimpl Workflow.Event.Payload, for: Workflow.Event.Payload.LegacyFanOutCompleted do
  def type(_payload), do: :fan_out_completed
  def to_map(payload), do: Map.from_struct(payload)
end

defimpl Workflow.Event.Payload, for: Workflow.Event.Payload.IterationStarted do
  def type(_payload), do: :iteration_started
  def to_map(payload), do: Map.from_struct(payload)
end

defimpl Workflow.Event.Payload, for: Workflow.Event.Payload.LoopDecision do
  def type(_payload), do: :loop_decision
  def to_map(payload), do: Map.from_struct(payload)
end

defimpl Workflow.Event.Payload, for: Workflow.Event.Payload.LoopCompleted do
  def type(_payload), do: :loop_completed
  def to_map(payload), do: Map.from_struct(payload)
end

defimpl Workflow.Event.Payload, for: Workflow.Event.Payload.LoopExhausted do
  def type(_payload), do: :loop_exhausted
  def to_map(payload), do: Map.from_struct(payload)
end

defimpl Workflow.Event.Payload, for: Workflow.Event.Payload.Accumulate do
  def type(_payload), do: :accumulate
  def to_map(payload), do: Map.from_struct(payload)
end

defimpl Workflow.Event.Payload, for: Workflow.Event.Payload.VerifyStarted do
  def type(_payload), do: :verify_started
  def to_map(payload), do: Map.from_struct(payload)
end

defimpl Workflow.Event.Payload, for: Workflow.Event.Payload.VerifySettled do
  def type(_payload), do: :verify_settled
  def to_map(payload), do: Map.from_struct(payload)
end

defimpl Workflow.Event.Payload, for: Workflow.Event.Payload.RefineStarted do
  def type(_payload), do: :refine_started
  def to_map(payload), do: Workflow.Event.Payload.RefineStarted.to_map(payload)
end

defimpl Workflow.Event.Payload, for: Workflow.Event.Payload.RefineRoundStarted do
  def type(_payload), do: :refine_round_started
  def to_map(payload), do: Map.from_struct(payload)
end

defimpl Workflow.Event.Payload, for: Workflow.Event.Payload.RefineRoundDecision do
  def type(_payload), do: :refine_round_decision
  def to_map(payload), do: Workflow.Event.Payload.RefineRoundDecision.to_map(payload)
end

defimpl Workflow.Event.Payload, for: Workflow.Event.Payload.RefineRoleFailed do
  def type(_payload), do: :refine_role_failed
  def to_map(payload), do: Workflow.Event.Payload.RefineRoleFailed.to_map(payload)
end

defimpl Workflow.Event.Payload, for: Workflow.Event.Payload.RefineCompleted do
  def type(_payload), do: :refine_completed
  def to_map(payload), do: Workflow.Event.Payload.RefineCompleted.to_map(payload)
end

defimpl Workflow.Event.Payload, for: Workflow.Event.Payload.RefineNonConverged do
  def type(_payload), do: :refine_non_converged
  def to_map(payload), do: Workflow.Event.Payload.RefineNonConverged.to_map(payload)
end

defimpl Workflow.Event.Payload, for: Workflow.Event.Payload.RefineGateEvaluated do
  def type(_payload), do: :refine_gate_evaluated
  def to_map(payload), do: Map.from_struct(payload)
end

defimpl Workflow.Event.Payload, for: Workflow.Event.Payload.RefineInputInvalid do
  def type(_payload), do: :refine_input_invalid
  def to_map(payload), do: Map.from_struct(payload)
end

defimpl Workflow.Event.Payload, for: Workflow.Event.Payload.JudgeStarted do
  def type(_payload), do: :judge_started
  def to_map(payload), do: Map.from_struct(payload)
end

defimpl Workflow.Event.Payload, for: Workflow.Event.Payload.JudgeSettled do
  def type(_payload), do: :judge_settled
  def to_map(payload), do: Map.from_struct(payload)
end

defimpl Workflow.Event.Payload, for: Workflow.Event.Payload.RunCompleted do
  def type(_payload), do: :run_completed
  def to_map(payload), do: Map.from_struct(payload)
end

defimpl Workflow.Event.Payload, for: Workflow.Event.Payload.RunFailed do
  def type(_payload), do: :run_failed
  def to_map(payload), do: Workflow.Event.Payload.RunFailed.to_map(payload)
end
