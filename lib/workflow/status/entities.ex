defmodule Workflow.Status.Phase do
  @moduledoc "A journal-derived workflow phase and its attempts."

  @enforce_keys [:id, :name, :address, :agents]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          address: Workflow.Node.address() | nil,
          agents: [Workflow.Status.Agent.t()]
        }
end

defmodule Workflow.Status.ProviderFailure do
  @moduledoc "Normalized provider failure detail attached to a failed attempt."

  @enforce_keys [:kind, :detail]
  defstruct @enforce_keys

  @type t :: %__MODULE__{kind: atom(), detail: term()}
end

defmodule Workflow.Status.Agent do
  @moduledoc "One journal-derived provider attempt in the run read model."

  @enforce_keys [
    :address,
    :iteration,
    :label,
    :prompt,
    :result,
    :usage,
    :attempt,
    :idempotency_key,
    :status,
    :activity,
    :phase_id,
    :phase_name
  ]
  defstruct @enforce_keys ++ [provider_failure: nil]

  @type t :: %__MODULE__{
          address: Workflow.Node.address(),
          iteration: non_neg_integer(),
          label: String.t() | nil,
          prompt: String.t() | nil,
          result: term(),
          usage: Workflow.Provider.Usage.t(),
          attempt: non_neg_integer(),
          idempotency_key: Workflow.IdempotencyKey.t() | nil,
          status: :running | :completed | :failed,
          activity: [Workflow.Provider.Activity.t()],
          phase_id: String.t(),
          phase_name: String.t(),
          provider_failure: Workflow.Status.ProviderFailure.t() | nil
        }
end

defmodule Workflow.Status.Rejection do
  @moduledoc "One rejected provider attempt retained for retry history."

  @enforce_keys [
    :address,
    :iteration,
    :attempt,
    :label,
    :prompt,
    :output,
    :reason,
    :activity,
    :phase_id,
    :phase_name
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          address: Workflow.Node.address(),
          iteration: non_neg_integer(),
          attempt: non_neg_integer(),
          label: String.t() | nil,
          prompt: String.t(),
          output: term(),
          reason: term(),
          activity: [Workflow.Provider.Activity.t()],
          phase_id: String.t(),
          phase_name: String.t()
        }
end

defmodule Workflow.Status.Failure do
  @moduledoc "The terminal failure reconstructed for a run."

  @enforce_keys [:address, :iteration, :attempts, :reason]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          address: Workflow.Node.address() | nil,
          iteration: non_neg_integer() | nil,
          attempts: non_neg_integer(),
          reason: term()
        }
end

defmodule Workflow.Status.Verification do
  @moduledoc "The settled outcome of a verification panel."

  @enforce_keys [:address, :confirmations, :total, :threshold, :survived]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          address: Workflow.Node.address(),
          confirmations: non_neg_integer(),
          total: non_neg_integer(),
          threshold: :majority | :unanimous | :any | pos_integer(),
          survived: boolean()
        }
end

defmodule Workflow.Status.Judgment do
  @moduledoc "The settled outcome of a judgment panel."

  @enforce_keys [:address, :scores, :pick, :winner]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          address: Workflow.Node.address(),
          scores: map(),
          pick: atom(),
          winner: term()
        }
end

defmodule Workflow.Status.RawRef do
  @moduledoc "A stable reference from a read-model value back to its journal event."

  @enforce_keys [:run_id, :seq, :type]
  defstruct @enforce_keys ++ [address: nil]

  @type t :: %__MODULE__{
          run_id: String.t(),
          seq: non_neg_integer() | nil,
          type: String.t(),
          address: Workflow.Node.address() | nil
        }
end

defmodule Workflow.Status.RawRefs do
  @moduledoc "Run-level journal references retained by the read model."

  @enforce_keys [:journal]
  defstruct @enforce_keys

  @type t :: %__MODULE__{journal: [Workflow.Status.RawRef.t()]}
end

defmodule Workflow.Status.RefineRefs do
  @moduledoc "Journal references owned by one refine projection."

  alias Workflow.Status.RawRef

  @enforce_keys [
    :started,
    :rounds,
    :decisions,
    :role_failures,
    :gates,
    :gate_role_agents,
    :terminal,
    :journal
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          started: RawRef.t() | nil,
          rounds: [RawRef.t()],
          decisions: [RawRef.t()],
          role_failures: [RawRef.t()],
          gates: [RawRef.t()],
          gate_role_agents: [RawRef.t()],
          terminal: RawRef.t() | nil,
          journal: [RawRef.t()]
        }
end

defmodule Workflow.Status.RoleFailureDefect do
  @moduledoc "A refine role failure projected into the final open-defect set."

  @enforce_keys [
    :kind,
    :role,
    :role_address,
    :reviewer,
    :reviewer_index,
    :id,
    :issue,
    :fix,
    :reason
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          kind: :role_failure,
          role: atom(),
          role_address: Workflow.Node.address(),
          reviewer: atom() | nil,
          reviewer_index: non_neg_integer() | nil,
          id: String.t(),
          issue: String.t(),
          fix: String.t(),
          reason: term()
        }
end

defmodule Workflow.Status.Refine do
  @moduledoc "The journal-derived read model for one refine node."

  alias Workflow.Refine.OpenFinding

  @enforce_keys [
    :address,
    :state,
    :converged,
    :rounds,
    :final_round,
    :open_findings,
    :final_open_defects,
    :failed_reviewers,
    :role_failures,
    :artifact_preview,
    :reviewer_decisions,
    :cold_read,
    :report_snippets,
    :raw_refs
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          address: Workflow.Node.address(),
          state: :running | :completed | :failed,
          converged: boolean() | nil,
          rounds: non_neg_integer(),
          final_round: non_neg_integer() | nil,
          open_findings: [OpenFinding.t()],
          final_open_defects: [OpenFinding.t() | Workflow.Status.RoleFailureDefect.t()],
          failed_reviewers: [atom()],
          role_failures: [Workflow.Refine.RoleFailure.t()],
          artifact_preview: String.t() | nil,
          reviewer_decisions: [Workflow.Refine.ReviewerDecision.t()],
          cold_read: Workflow.Refine.ColdRead.t() | nil,
          report_snippets: [String.t()],
          raw_refs: Workflow.Status.RefineRefs.t()
        }
end

defmodule Workflow.Status.ToolActivity do
  @moduledoc "A provider activity item paired with its journal reference."

  @enforce_keys [:entry, :raw_ref]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          entry: Workflow.Provider.Activity.t(),
          raw_ref: Workflow.Status.RawRef.t()
        }
end
