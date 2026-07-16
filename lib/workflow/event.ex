defmodule Workflow.Event do
  @moduledoc """
  A single committed journal event: `agent-loops/journal@1`.

  The log is **versioned and additive**. `schema` pins the envelope version and
  `type` belongs to the closed `event_type/0` vocabulary. A new event kind must be
  added to that vocabulary and constructed here.

  Each event kind owns a distinct payload struct. Persisted version-one events
  that still contain plain payload maps are upgraded by `normalize/1` at the
  journal boundary. `run_id`/`seq` are stamped by the writer at commit time.
  Events carry no wall-clock — ordering is the monotonic `seq`, which keeps the
  fold deterministic.
  """

  alias Workflow.Event.Payload, as: P
  alias Workflow.IdempotencyKey
  alias Workflow.Node.Agent
  alias Workflow.Node.GenericFanout
  alias Workflow.Node.Judge
  alias Workflow.Node.Parallel
  alias Workflow.Node.Pipeline
  alias Workflow.Node.Refine
  alias Workflow.Node.Refine.ColdReadGate
  alias Workflow.Node.Refine.Gates
  alias Workflow.Node.Refine.HaltGate
  alias Workflow.Node.Refine.RepairGate
  alias Workflow.Node.Verify
  alias Workflow.PlanIdentity
  alias Workflow.Provider.Activity
  alias Workflow.Refine.Artifact
  alias Workflow.Refine.ColdRead
  alias Workflow.Refine.OpenFinding
  alias Workflow.Refine.Review
  alias Workflow.Refine.Reviewer
  alias Workflow.Refine.ReviewerAdapter
  alias Workflow.Refine.ReviewerDecision
  alias Workflow.Refine.RoleFailure
  alias Workflow.Refine.RoundDecision
  alias Workflow.Refine.TerminalProjection
  alias Workflow.Run.Input
  alias Workflow.Schema

  @schema 1
  @enforce_keys [:type, :payload]
  defstruct [:run_id, :seq, :type, :payload, schema: @schema]

  @type event_type :: P.event_type()

  @type payload ::
          P.RunStarted.t()
          | P.PhaseEntered.t()
          | P.LogEmitted.t()
          | P.AgentStarted.t()
          | P.AgentActivity.t()
          | P.AgentAttemptRejected.t()
          | P.AgentCommitted.t()
          | P.AgentFailed.t()
          | P.ParallelStarted.t()
          | P.ParallelCompleted.t()
          | P.PipelineStarted.t()
          | P.PipelineCompleted.t()
          | P.FanoutStarted.t()
          | P.FanoutCompleted.t()
          | P.FanoutFailed.t()
          | P.LegacyFanOutStarted.t()
          | P.LegacyFanOutCompleted.t()
          | P.IterationStarted.t()
          | P.LoopDecision.t()
          | P.LoopCompleted.t()
          | P.LoopExhausted.t()
          | P.Accumulate.t()
          | P.VerifyStarted.t()
          | P.VerifySettled.t()
          | P.RefineStarted.t()
          | P.RefineRoundStarted.t()
          | P.RefineRoundDecision.t()
          | P.RefineRoleFailed.t()
          | P.RefineCompleted.t()
          | P.RefineNonConverged.t()
          | P.RefineGateEvaluated.t()
          | P.RefineInputInvalid.t()
          | P.JudgeStarted.t()
          | P.JudgeSettled.t()
          | P.RunCompleted.t()
          | P.RunFailed.t()

  @type t :: %__MODULE__{
          run_id: String.t() | nil,
          seq: non_neg_integer() | nil,
          type: event_type(),
          payload: payload(),
          schema: pos_integer()
        }

  @type persisted_t :: %__MODULE__{
          run_id: String.t() | nil,
          seq: non_neg_integer() | nil,
          type: event_type(),
          payload: payload() | %{optional(atom()) => term()},
          schema: pos_integer()
        }

  @spec schema_version() :: pos_integer()
  def schema_version, do: @schema

  @spec payload_map(t()) :: map()
  def payload_map(%__MODULE__{payload: payload}), do: P.to_map(payload)

  @spec event(payload()) :: t()
  defp event(payload), do: %__MODULE__{type: P.type(payload), payload: payload}

  @doc "Upgrades a persisted version-one payload map to its enforced event payload struct."
  @spec normalize(persisted_t()) :: t()
  def normalize(%__MODULE__{type: type, payload: %_{} = payload, run_id: run_id} = event) do
    case P.type(payload) do
      ^type -> %{event | payload: hydrate_nested_payload(payload, run_id)}
      payload_type -> raise ArgumentError, "#{inspect(type)} event has #{inspect(payload_type)} payload"
    end
  end

  def normalize(%__MODULE__{type: type, payload: legacy, run_id: run_id} = event) when is_map(legacy) do
    {module, defaults} = payload_spec(type, legacy)

    attrs =
      legacy
      |> upgrade_legacy_payload(type)
      |> then(&Map.merge(defaults, &1))

    payload = module |> hydrate_payload(attrs) |> hydrate_nested_payload(run_id)

    %{event | payload: payload}
  end

  defp hydrate_payload(module, attrs) do
    fields = module.__struct__() |> Map.keys() |> List.delete(:__struct__)
    payload = struct!(module, Map.take(attrs, fields))
    extras = Map.drop(attrs, [:__struct__ | fields])
    Map.merge(payload, extras)
  end

  defp hydrate_nested_payload(%P.AgentActivity{} = payload, _run_id),
    do: %{payload | entry: hydrate_activity(payload.entry)}

  defp hydrate_nested_payload(%P.AgentAttemptRejected{} = payload, _run_id),
    do: %{payload | activity: hydrate_activity_list(payload.activity)}

  defp hydrate_nested_payload(%P.AgentCommitted{} = payload, _run_id),
    do: %{payload | activity: hydrate_activity_list(payload.activity)}

  defp hydrate_nested_payload(%P.AgentFailed{} = payload, _run_id),
    do: %{payload | activity: hydrate_activity_list(payload.activity)}

  defp hydrate_nested_payload(%P.RefineStarted{} = payload, _run_id) do
    %{
      payload
      | input: hydrate_refine_input(payload.input),
        reviewers: Enum.map(payload.reviewers, &hydrate_reviewer/1),
        reviser: hydrate_artifact_agent(payload.reviser),
        gates: hydrate_refine_gates(payload.gates)
    }
  end

  defp hydrate_nested_payload(%P.RefineRoundDecision{} = payload, _run_id) do
    %{
      payload
      | reviewer_decisions: Enum.map(payload.reviewer_decisions, &hydrate_reviewer_decision/1),
        open_findings: Enum.map(payload.open_findings, &hydrate_open_finding/1),
        role_failures: Enum.map(payload.role_failures, &hydrate_role_failure/1)
    }
  end

  defp hydrate_nested_payload(%P.RefineRoleFailed{} = payload, _run_id),
    do: %{payload | activity: hydrate_activity_list(payload.activity)}

  defp hydrate_nested_payload(%P.RefineCompleted{} = payload, _run_id), do: hydrate_terminal_payload(payload)
  defp hydrate_nested_payload(%P.RefineNonConverged{} = payload, _run_id), do: hydrate_terminal_payload(payload)

  defp hydrate_nested_payload(%P.RunFailed{reason: {:outcome_unknown, %IdempotencyKey{}}} = payload, _run_id), do: payload

  defp hydrate_nested_payload(%P.RunFailed{reason: {:outcome_unknown, attempt}} = payload, run_id) do
    key = hydrate_attempt(attempt, run_id)
    %{payload | reason: {:outcome_unknown, key}}
  end

  defp hydrate_nested_payload(%P.RunFailed{} = payload, _run_id), do: payload
  defp hydrate_nested_payload(payload, _run_id), do: payload

  defp hydrate_attempt(%{address: address, iteration: iteration, attempt: attempt}, run_id) do
    %IdempotencyKey{run_id: run_id, node_path: address, iteration: iteration, attempt: attempt}
  end

  defp hydrate_terminal_payload(payload) do
    %{
      payload
      | open_findings: Enum.map(payload.open_findings, &hydrate_open_finding/1),
        role_failures: Enum.map(payload.role_failures, &hydrate_role_failure/1),
        reviewer_decisions: Enum.map(payload.reviewer_decisions, &hydrate_reviewer_decision/1),
        cold_read: hydrate_cold_read(payload.cold_read)
    }
  end

  defp hydrate_cold_read(nil), do: nil
  defp hydrate_cold_read(%ColdRead{} = cold_read), do: cold_read
  defp hydrate_cold_read(cold_read) when is_map(cold_read), do: ColdRead.from_payload(cold_read)

  defp hydrate_reviewer_decision(%ReviewerDecision{} = decision), do: decision
  defp hydrate_reviewer_decision(decision) when is_map(decision), do: ReviewerDecision.from_payload(decision)

  defp hydrate_open_finding(%OpenFinding{} = finding), do: finding
  defp hydrate_open_finding(finding) when is_map(finding), do: OpenFinding.from_payload(finding)

  defp hydrate_role_failure(%RoleFailure{} = failure), do: failure
  defp hydrate_role_failure(failure) when is_map(failure), do: RoleFailure.from_payload(failure)

  defp hydrate_activity_list(activity), do: Enum.map(activity, &hydrate_activity/1)
  defp hydrate_activity(%Activity{} = activity), do: activity
  defp hydrate_activity(activity) when is_map(activity), do: Activity.normalize!(activity)

  defp payload_spec(:run_started, _payload) do
    {P.RunStarted,
     %{
       budget: nil,
       script_path: nil,
       workspace_root: nil,
       args: %{},
       args_digest: nil,
       tree_fingerprint: nil
     }}
  end

  defp payload_spec(:phase_entered, _payload), do: {P.PhaseEntered, %{}}
  defp payload_spec(:log_emitted, _payload), do: {P.LogEmitted, %{}}
  defp payload_spec(:agent_started, _payload), do: {P.AgentStarted, %{label: nil}}

  defp payload_spec(:agent_activity, _payload), do: {P.AgentActivity, %{activity_index: nil, label: nil}}

  defp payload_spec(:agent_attempt_rejected, _payload), do: {P.AgentAttemptRejected, %{label: nil, activity: []}}

  defp payload_spec(:agent_committed, _payload), do: {P.AgentCommitted, %{label: nil, activity: []}}

  defp payload_spec(:agent_failed, _payload), do: {P.AgentFailed, %{usage: nil, activity: []}}
  defp payload_spec(:parallel_started, _payload), do: {P.ParallelStarted, %{}}
  defp payload_spec(:parallel_completed, _payload), do: {P.ParallelCompleted, %{}}
  defp payload_spec(:pipeline_started, _payload), do: {P.PipelineStarted, %{}}
  defp payload_spec(:pipeline_completed, _payload), do: {P.PipelineCompleted, %{}}
  defp payload_spec(:fanout_started, _payload), do: {P.FanoutStarted, %{iteration: nil}}
  defp payload_spec(:fanout_completed, _payload), do: {P.FanoutCompleted, %{iteration: nil}}
  defp payload_spec(:fanout_failed, _payload), do: {P.FanoutFailed, %{iteration: nil}}
  defp payload_spec(:fan_out_started, _payload), do: {P.LegacyFanOutStarted, %{}}
  defp payload_spec(:fan_out_completed, _payload), do: {P.LegacyFanOutCompleted, %{}}
  defp payload_spec(:iteration_started, _payload), do: {P.IterationStarted, %{}}

  defp payload_spec(:loop_decision, _payload),
    do: {P.LoopDecision, %{predicate_result: nil, exhausted: false, source_address: nil}}

  defp payload_spec(:loop_completed, _payload), do: {P.LoopCompleted, %{exhausted: false, reason: nil}}

  defp payload_spec(:loop_exhausted, _payload), do: {P.LoopExhausted, %{}}
  defp payload_spec(:accumulate, _payload), do: {P.Accumulate, %{}}
  defp payload_spec(:verify_started, _payload), do: {P.VerifyStarted, %{}}
  defp payload_spec(:verify_settled, _payload), do: {P.VerifySettled, %{}}

  defp payload_spec(:refine_started, payload) do
    defaults = %{
      gates: %Gates{},
      max_concurrency: payload |> Map.get(:reviewers, []) |> length(),
      reviewer_timeout_ms: nil,
      artifact_schema_version: 1,
      review_schema_version: 1,
      review_adapter_versions: %{}
    }

    {P.RefineStarted, defaults}
  end

  defp payload_spec(:refine_round_started, _payload), do: {P.RefineRoundStarted, %{}}

  defp payload_spec(:refine_round_decision, payload) do
    {P.RefineRoundDecision,
     %{
       reviewer_decisions: [],
       open_findings: [],
       role_failures: [],
       failed_reviewers: failed_reviewers(payload),
       report_snippets: []
     }}
  end

  defp payload_spec(:refine_role_failed, _payload) do
    {P.RefineRoleFailed,
     %{
       round: nil,
       reviewer: nil,
       reviewer_index: nil,
       detail: nil,
       usage: nil,
       activity: []
     }}
  end

  defp payload_spec(:refine_completed, payload) do
    {P.RefineCompleted,
     %{
       open_findings: [],
       role_failures: [],
       failed_reviewers: failed_reviewers(payload),
       reviewer_decisions: [],
       report_snippets: [],
       cold_read: nil
     }}
  end

  defp payload_spec(:refine_non_converged, payload) do
    {P.RefineNonConverged,
     %{
       converged: false,
       open_findings: [],
       role_failures: [],
       failed_reviewers: failed_reviewers(payload),
       reviewer_decisions: [],
       report_snippets: [],
       cold_read: nil,
       reason: :max_rounds
     }}
  end

  defp payload_spec(:refine_gate_evaluated, _payload), do: {P.RefineGateEvaluated, %{input_refs: []}}

  defp payload_spec(:refine_input_invalid, _payload), do: {P.RefineInputInvalid, %{}}
  defp payload_spec(:judge_started, _payload), do: {P.JudgeStarted, %{}}
  defp payload_spec(:judge_settled, _payload), do: {P.JudgeSettled, %{}}
  defp payload_spec(:run_completed, _payload), do: {P.RunCompleted, %{}}
  defp payload_spec(:run_failed, _payload), do: {P.RunFailed, %{}}

  defp upgrade_legacy_payload(payload, type) when type in [:refine_completed, :refine_non_converged] do
    payload
    |> Map.update(:reviewer_decisions, [], &Enum.map(&1, fn decision -> upgrade_reviewer_decision(decision) end))
    |> Map.update(:cold_read, nil, &upgrade_cold_read/1)
  end

  defp upgrade_legacy_payload(payload, :refine_round_decision) do
    Map.update(payload, :reviewer_decisions, [], &Enum.map(&1, fn decision -> upgrade_reviewer_decision(decision) end))
  end

  defp upgrade_legacy_payload(payload, :refine_started) do
    Map.put_new(payload, :gates, %Gates{})
  end

  defp upgrade_legacy_payload(%{decision: :stop} = payload, :loop_decision) do
    payload
    |> Map.put(:decision, {:stop, Map.get(payload, :reason, :until)})
    |> Map.delete(:reason)
  end

  defp upgrade_legacy_payload(payload, _type), do: payload

  defp upgrade_cold_read(%{state: :completed} = cold_read) do
    Map.update!(cold_read, :reviewer_decision, &upgrade_reviewer_decision/1)
  end

  defp upgrade_cold_read(cold_read), do: cold_read

  defp upgrade_reviewer_decision(%ReviewerDecision{} = decision), do: ReviewerDecision.to_payload(decision)

  defp upgrade_reviewer_decision(%{outcome: outcome} = decision)
       when outcome in [:clear, :approved_with_findings, :rejected, :failed] and not is_map_key(decision, :approved) and
              not is_map_key(decision, :clear) and not is_map_key(decision, :status), do: decision

  defp upgrade_reviewer_decision(decision)
       when is_map_key(decision, :approved) and is_map_key(decision, :clear) and not is_map_key(decision, :outcome) do
    decision
    |> Map.put_new(:adapter, ReviewerAdapter.default())
    |> Map.put_new(:status, :completed)
    |> upgrade_legacy_reviewer_decision()
  end

  defp upgrade_reviewer_decision(decision)
       when is_map_key(decision, :approved) or is_map_key(decision, :clear) or is_map_key(decision, :status) do
    raise ArgumentError, "contradictory legacy reviewer decision: #{inspect(decision)}"
  end

  defp upgrade_reviewer_decision(decision), do: decision

  defp upgrade_legacy_reviewer_decision(%{approved: true, clear: true, status: :completed} = decision),
    do: put_reviewer_outcome(decision, :clear)

  defp upgrade_legacy_reviewer_decision(%{approved: true, clear: false, status: :completed} = decision),
    do: put_reviewer_outcome(decision, :approved_with_findings)

  defp upgrade_legacy_reviewer_decision(%{approved: false, clear: false, status: :completed} = decision),
    do: put_reviewer_outcome(decision, :rejected)

  defp upgrade_legacy_reviewer_decision(%{approved: false, clear: false, status: :failed} = decision),
    do: put_reviewer_outcome(decision, :failed)

  defp upgrade_legacy_reviewer_decision(decision) do
    raise ArgumentError, "contradictory legacy reviewer decision: #{inspect(decision)}"
  end

  defp put_reviewer_outcome(decision, outcome) do
    decision
    |> Map.drop([:approved, :clear, :status])
    |> Map.put(:outcome, outcome)
  end

  defp failed_reviewers(payload) do
    payload
    |> Map.get(:role_failures, [])
    |> Enum.map(&Map.get(&1, :reviewer))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  @doc """
  The run's start marker. `budget` is the per-run token target the ledger folds
  against, or `nil` for an unbounded run. Recording it here (not in process state)
  keeps the ledger a pure fold and survives resume: the target is read back from
  this journaled event rather than re-supplied.

  `script_path` is the canonical on-disk source the tree was compiled from (or
  `nil` when a tree was supplied directly). `workspace_root` is its canonical,
  containing execution directory. Journaling both lets `resume` recover the
  workflow and the same Codex filesystem context from the run alone. Both fields
  are additive; older runs hydrate them to `nil` and can derive a safe root from a
  recovered script path. `args` is the normalized immutable run input; its
  digest and the compiled tree fingerprint make invocation identity explicit.
  """
  def run_started(
        %Workflow.Tree{} = tree,
        budget \\ nil,
        script_path \\ nil,
        workspace_root \\ nil,
        args \\ %{},
        tree_fingerprint \\ nil
      ) do
    {:ok, args} = Input.normalize(args)

    event(%P.RunStarted{
      tree_name: tree.name,
      tree_version: tree.version,
      node_count: length(tree.nodes),
      budget: budget,
      script_path: script_path,
      workspace_root: workspace_root,
      args: args,
      args_digest: Input.digest(args),
      tree_fingerprint: tree_fingerprint || PlanIdentity.fingerprint(tree)
    })
  end

  def phase_entered(%Workflow.Node.Phase{} = node) do
    event(%P.PhaseEntered{address: node.address, name: node.name})
  end

  def log_emitted(%Workflow.Node.Log{} = node) do
    event(%P.LogEmitted{address: node.address, message: node.message})
  end

  def agent_committed(%Agent{} = node, iteration, key, result, usage, activity \\ []) do
    event(%P.AgentCommitted{
      address: node.address,
      iteration: iteration,
      idempotency_key: key,
      label: node.label,
      prompt: node.prompt,
      result: durable_agent_result(result),
      usage: usage,
      activity: Activity.normalize_all!(activity)
    })
  end

  defp durable_agent_result(%Review{} = review), do: Review.to_payload(review)
  defp durable_agent_result(result), do: result

  @doc "Durable at-most-once marker written before a provider effect begins."
  def agent_started(%Agent{} = node, iteration, key) do
    event(%P.AgentStarted{
      address: node.address,
      iteration: iteration,
      attempt: key.attempt,
      idempotency_key: key,
      label: node.label,
      prompt: node.prompt
    })
  end

  @doc """
  A non-terminal activity item observed while an agent turn is still running.

  This is progress telemetry, not the authoritative result of the paid turn. The
  final outcome remains `agent_committed` or `agent_attempt_rejected`; this event
  only lets journal-backed read surfaces show long-running provider streams before
  the turn exits.
  """
  def agent_activity(%Agent{} = node, iteration, attempt, activity_index, entry) do
    event(%P.AgentActivity{
      address: node.address,
      iteration: iteration,
      attempt: attempt,
      activity_index: activity_index,
      label: node.label,
      prompt: node.prompt,
      entry: Activity.normalize!(entry)
    })
  end

  def agent_activity(%Agent{} = node, iteration, attempt, entry) do
    agent_activity(node, iteration, attempt, nil, entry)
  end

  @doc """
  A single fail-closed attempt whose output did not conform to the schema. Records
  the rejected output and the validator's reason so replay reconstructs every retry
  decision; the paid `usage` is still ledgered.
  """
  def agent_attempt_rejected(%Agent{} = node, iteration, attempt, output, reason, usage, activity \\ []) do
    event(%P.AgentAttemptRejected{
      address: node.address,
      iteration: iteration,
      attempt: attempt,
      label: node.label,
      prompt: node.prompt,
      output: output,
      reason: reason,
      usage: usage,
      activity: Activity.normalize_all!(activity)
    })
  end

  @doc """
  Terminal node failure after the retry budget is exhausted (exit-8 / malformed
  structured output). This is the run's terminal event on the fail path — there is
  no `run_completed`.
  """
  def agent_failed(%Agent{} = node, iteration, attempts, reason, usage \\ nil, activity \\ []) do
    event(%P.AgentFailed{
      address: node.address,
      iteration: iteration,
      attempts: attempts,
      reason: reason,
      usage: usage,
      activity: Activity.normalize_all!(activity)
    })
  end

  @doc """
  Barrier fan-out markers. `parallel_started` records the branch count so a fold can
  see the fan-out width; `parallel_completed` marks the barrier join. Each branch's
  own paid turn is journaled as an ordinary `agent_*` event at its branch address,
  so these markers carry no results — they only bracket the concurrent region.
  """
  def parallel_started(%Parallel{} = node) do
    event(%P.ParallelStarted{address: node.address, branch_count: length(node.branches)})
  end

  def parallel_completed(%Parallel{} = node) do
    event(%P.ParallelCompleted{address: node.address})
  end

  @doc """
  Per-item fan-out markers. `pipeline_started` records the concrete `items` and the
  stage count; `pipeline_completed` marks the join. Each item lane's stage turns are
  journaled as ordinary `agent_*` events at their `[item, stage]` addresses.
  """
  def pipeline_started(%Pipeline{} = node) do
    stage_count = node.lanes |> List.first([]) |> length()

    event(%P.PipelineStarted{
      address: node.address,
      items: node.items,
      item_count: length(node.items),
      stage_count: stage_count
    })
  end

  def pipeline_completed(%Pipeline{} = node) do
    event(%P.PipelineCompleted{address: node.address})
  end

  @doc """
  Generic fanout markers. `fanout_started` records the decided width before any
  lane runs; top-level fanouts carry `iteration: nil`, while loop-body fanouts can
  qualify the marker by the owning loop iteration. `fanout_failed` is terminal for
  declared fanout failures such as `on_zero: :fail`.
  """
  def fanout_started(%GenericFanout{} = node, width, iteration \\ nil) do
    event(%P.FanoutStarted{
      address: node.address,
      iteration: iteration,
      width_expr: node.width,
      width: width,
      bind: node.bind
    })
  end

  def fanout_completed(%GenericFanout{} = node, iteration \\ nil) do
    event(%P.FanoutCompleted{address: node.address, iteration: iteration})
  end

  def fanout_failed(%GenericFanout{} = node, reason, iteration \\ nil) do
    event(%P.FanoutFailed{address: node.address, iteration: iteration, reason: reason})
  end

  @doc """
  Loop control-flow markers and the declared-reduction event. **Control-flow
  decisions are journaled**, so a resume replays them rather than recomputing them
  from a ledger/accumulator fold that reflects the whole run instead of the
  historical decision point.

    * `iteration_started` — enters loop iteration `n` at the loop's address.
    * `loop_decision` — the journaled generic loop decision for iteration `n`.
    * `loop_completed` — the loop's terminal bracket, recording how many iterations ran.
    * `loop_exhausted` — terminal failure when `on_exhausted: :fail` fires.
    * `accumulate` — one `collect`'s reduction: the exact deduped items `added` to
      `into` this iteration, plus the resulting accumulator `size`. Folding these
      rebuilds every accumulator exactly on resume.
  """
  def iteration_started(loop, iteration) do
    event(%P.IterationStarted{address: loop.address, iteration: iteration})
  end

  def loop_decision(loop, iteration, decision, opts \\ []) do
    event(%P.LoopDecision{
      address: loop_address(loop),
      iteration: iteration,
      decision: decision,
      predicate_result: Keyword.get(opts, :predicate_result),
      exhausted: Keyword.get(opts, :exhausted, false),
      source_address: Keyword.get(opts, :source_address)
    })
  end

  def loop_completed(loop, iterations, opts \\ []) do
    event(%P.LoopCompleted{
      address: loop_address(loop),
      iterations: iterations,
      exhausted: Keyword.get(opts, :exhausted, false),
      reason: Keyword.get(opts, :reason)
    })
  end

  def loop_exhausted(loop, iterations, reason) do
    event(%P.LoopExhausted{
      address: loop_address(loop),
      iterations: iterations,
      reason: reason
    })
  end

  defp loop_address(%{address: address}), do: address
  defp loop_address(address) when is_list(address), do: address

  def accumulate(%Workflow.Node.Collect{} = node, iteration, seen_by, added, size) do
    event(%P.Accumulate{
      address: node.address,
      into: node.into,
      iteration: iteration,
      seen_by: seen_by,
      added: added,
      size: size
    })
  end

  @doc """
  Verification panel markers. `verify_started` records the panel shape (its `mode`
  and voter count); `verify_settled` records the **journal-folded outcome**: how
  many voters `confirmations` confirmed out of `total`, the `threshold` applied,
  and whether the finding `survived`. Each voter's own vote is journaled as an
  ordinary `agent_committed` event at its voter address, so `verify_settled` is a
  pure summary a resume replays.
  """
  def verify_started(%Verify{} = node) do
    event(%P.VerifyStarted{
      address: node.address,
      mode: verify_mode_tag(node.mode),
      voter_count: length(node.voters),
      threshold: node.threshold
    })
  end

  def verify_settled(%Verify{} = node, confirmations, total, survived) when is_boolean(survived) do
    event(%P.VerifySettled{
      address: node.address,
      confirmations: confirmations,
      total: total,
      threshold: node.threshold,
      survived: survived
    })
  end

  defp verify_mode_tag({:voters, _n}), do: :voters
  defp verify_mode_tag({:lenses, _lenses}), do: :lenses

  @doc """
  Refine markers. `refine_started` records the static role descriptors, each
  round records the reviewed artifact, `refine_round_decision` records the folded
  reviewer outcome, and `refine_completed` exposes the bindable final artifact.
  """
  def refine_started(%Refine{} = node) do
    event(%P.RefineStarted{
      address: node.address,
      input: node.input,
      max_rounds: node.max_rounds,
      until: node.until,
      on_non_convergence: node.on_non_convergence,
      max_concurrency: node.max_concurrency || length(node.reviewers),
      reviewer_timeout_ms: node.reviewer_timeout_ms,
      reviewers: node.reviewers,
      reviser: node.reviser,
      gates: node.gates,
      artifact_schema_version: 1,
      review_schema_version: 1,
      review_adapter_versions: review_adapter_versions(node.reviewers)
    })
  end

  def refine_round_started(%Refine{} = node, round, artifact) do
    event(%P.RefineRoundStarted{
      address: node.address,
      round: round,
      artifact: artifact
    })
  end

  def refine_round_decision(%Refine{} = node, round, %RoundDecision{} = decision) do
    event(%P.RefineRoundDecision{
      address: node.address,
      round: round,
      consensus: decision.consensus,
      approval_count: decision.approval_count,
      total: decision.total,
      reviewer_decisions: decision.reviewer_decisions,
      artifact: decision.artifact,
      open_findings: decision.open_findings,
      role_failures: decision.role_failures,
      failed_reviewers: decision.failed_reviewers,
      report_snippets: decision.report_snippets
    })
  end

  def refine_role_failed(%RoleFailure{} = role_failure) do
    event(%P.RefineRoleFailed{
      address: role_failure.address,
      role: role_failure.role,
      role_address: role_failure.role_address,
      round: role_failure.round,
      reviewer: role_failure.reviewer,
      reviewer_index: role_failure.reviewer_index,
      attempts: role_failure.attempts,
      reason: role_failure.reason,
      detail: role_failure.detail,
      usage: role_failure.usage,
      activity: role_failure.activity
    })
  end

  def refine_completed(%Refine{} = node, %TerminalProjection{} = projection) do
    event(%P.RefineCompleted{
      address: node.address,
      converged: projection.converged,
      final_round: projection.final_round,
      rounds: projection.rounds,
      artifact: projection.artifact,
      open_findings: projection.open_findings,
      role_failures: projection.role_failures,
      failed_reviewers: projection.failed_reviewers,
      reviewer_decisions: projection.reviewer_decisions,
      report_snippets: projection.report_snippets,
      cold_read: projection.cold_read
    })
  end

  def refine_non_converged(%Refine{} = node, %TerminalProjection{} = projection, reason) do
    event(%P.RefineNonConverged{
      address: node.address,
      converged: false,
      final_round: projection.final_round,
      rounds: projection.rounds,
      artifact: projection.artifact,
      open_findings: projection.open_findings,
      role_failures: projection.role_failures,
      failed_reviewers: projection.failed_reviewers,
      reviewer_decisions: projection.reviewer_decisions,
      report_snippets: projection.report_snippets,
      cold_read: projection.cold_read,
      reason: reason
    })
  end

  def refine_gate_evaluated(%Refine{} = node, gate, predicate, opts) when gate in [:cold_read, :repair, :halt] do
    event(%P.RefineGateEvaluated{
      address: node.address,
      gate: gate,
      predicate: predicate,
      result: Keyword.fetch!(opts, :result),
      input_round: Keyword.fetch!(opts, :input_round),
      input_refs: Keyword.fetch!(opts, :input_refs)
    })
  end

  def refine_input_invalid(%Refine{} = node, input, reason) do
    event(%P.RefineInputInvalid{address: node.address, input: input, reason: reason})
  end

  defp hydrate_refine_input({:producer, %Agent{}} = input), do: input
  defp hydrate_refine_input({:binding, name, ref}), do: {:binding, name, ref}

  defp hydrate_refine_input(%{kind: :producer} = descriptor),
    do: {:producer, hydrate_agent(descriptor, Artifact.schema())}

  defp hydrate_refine_input(%{kind: :binding, name: name, ref: ref}), do: {:binding, name, ref}

  defp hydrate_reviewer(%Reviewer{} = reviewer), do: reviewer

  defp hydrate_reviewer(%{index: index, name: name, prompt: prompt} = descriptor) do
    adapter = Map.get(descriptor, :adapter, ReviewerAdapter.default())

    %Reviewer{
      index: index,
      name: name,
      adapter: adapter,
      prompt: prompt,
      agent: hydrate_agent(descriptor, ReviewerAdapter.schema(adapter))
    }
  end

  defp hydrate_artifact_agent(%Agent{} = agent), do: agent
  defp hydrate_artifact_agent(descriptor), do: hydrate_agent(descriptor, Artifact.schema())

  defp hydrate_agent(%Agent{} = agent, _schema), do: agent

  defp hydrate_agent(%{address: address, prompt: prompt, retries: retries} = descriptor, schema) do
    %Agent{
      address: address,
      prompt: prompt,
      retries: retries,
      label: Map.get(descriptor, :label),
      schema: Schema.new(schema)
    }
  end

  defp hydrate_refine_gates(%Gates{} = gates) do
    %Gates{
      cold_read: hydrate_cold_read_gate(gates.cold_read),
      repair: hydrate_repair_gate(gates.repair),
      halt: hydrate_halt_gate(gates.halt)
    }
  end

  defp hydrate_refine_gates(gates) when is_map(gates) do
    %Gates{
      cold_read: gates |> Map.get(:cold_read) |> hydrate_cold_read_gate(),
      repair: gates |> Map.get(:repair) |> hydrate_repair_gate(),
      halt: gates |> Map.get(:halt) |> hydrate_halt_gate()
    }
  end

  defp hydrate_cold_read_gate(nil), do: nil
  defp hydrate_cold_read_gate(%ColdReadGate{} = gate), do: gate

  defp hydrate_cold_read_gate(%{predicate: predicate, descriptor: descriptor}) do
    %ColdReadGate{predicate: predicate, reviewer: hydrate_cold_read_reviewer(descriptor)}
  end

  defp hydrate_cold_read_reviewer(%Reviewer{} = reviewer), do: reviewer

  defp hydrate_cold_read_reviewer(%{name: name, prompt: prompt} = descriptor) do
    adapter = Map.get(descriptor, :adapter, ReviewerAdapter.default())

    %Reviewer{
      index: Map.get(descriptor, :index),
      name: name,
      adapter: adapter,
      prompt: prompt,
      agent: hydrate_agent(descriptor, ReviewerAdapter.schema(adapter))
    }
  end

  defp hydrate_repair_gate(nil), do: nil
  defp hydrate_repair_gate(%RepairGate{} = gate), do: gate

  defp hydrate_repair_gate(%{predicate: predicate, descriptor: descriptor}) do
    %RepairGate{predicate: predicate, agent: hydrate_artifact_agent(descriptor)}
  end

  defp hydrate_halt_gate(nil), do: nil
  defp hydrate_halt_gate(%HaltGate{} = gate), do: gate
  defp hydrate_halt_gate(%{predicate: predicate}), do: %HaltGate{predicate: predicate}

  defp review_adapter_versions(_reviewers) do
    Map.new(ReviewerAdapter.all(), &{&1, ReviewerAdapter.version(&1)})
  end

  @doc """
  Judge-panel markers. `judge_started` records the candidate list and criteria;
  `judge_settled` records the **journal-folded outcome**: the total `scores` per
  candidate, the `pick` strategy, and the `winner`. Each per-criterion score is
  journaled as an ordinary `agent_committed` event at its `[candidate, criterion]`
  address, so `judge_settled` is a pure summary a resume replays.
  """
  def judge_started(%Judge{} = node) do
    event(%P.JudgeStarted{
      address: node.address,
      candidates: node.candidates,
      criteria: node.by
    })
  end

  def judge_settled(%Judge{} = node, scores, winner) do
    event(%P.JudgeSettled{
      address: node.address,
      scores: scores,
      pick: node.pick,
      winner: winner
    })
  end

  def run_completed(value) do
    event(%P.RunCompleted{value: value})
  end

  @doc """
  Terminal runtime failure for an unexpected, non-resumable writer crash. Expected
  node failures still use their specific events (`agent_failed`, `fanout_failed`,
  etc.), and crashes with journaled retry progress stay resumable. This is the
  fallback that prevents an async writer crash from leaving a run permanently
  folded as running when no resume cursor can move it forward.
  """
  def run_failed(reason) do
    event(%P.RunFailed{reason: reason})
  end
end
