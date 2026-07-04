import type { Branded } from "./brand.ts"
import type { JsonValue } from "./json.ts"

export type CommandName =
  | "draft"
  | "help"
  | "inspect"
  | "list"
  | "resume"
  | "run"
  | "serve"
  | "status"
  | "test"
  | "validate"
  | "workflow"

export type CliFlagValue = string | boolean
export type CliFlags = Readonly<Record<string, CliFlagValue>>

export type CliRequest = {
  readonly command: CommandName
  readonly args: readonly string[]
  readonly flags: CliFlags
}

export type WorkflowProvider = "mock" | "sdk"
export type ApprovalPosture = "approved" | "not-approved"

export type WorkflowScriptRef =
  | { readonly t: "none" }
  | { readonly t: "unresolved"; readonly value: string }

export type RequestedRunId =
  | { readonly t: "none" }
  | { readonly t: "requested"; readonly value: string }

export type ProviderSelection =
  | { readonly t: "explicit"; readonly provider: WorkflowProvider }
  | { readonly t: "default_for_command"; readonly fallback: WorkflowProvider }

export type BackgroundStatusServerMode =
  | { readonly t: "disabled" }
  | {
    readonly t: "enabled"
    readonly host: string
    readonly port: number
    readonly portfilePollMs: number
    readonly portfileMaxPolls: number
  }

export type BackgroundLaunchMode =
  | { readonly t: "foreground" }
  | {
    readonly t: "launch"
    readonly handshakePollMs: number
    readonly handshakeMaxPolls: number
    readonly statusServer: BackgroundStatusServerMode
  }

export type WorkflowRunnableCommand = "resume" | "run" | "test" | "validate" | "workflow"

export type WorkflowCommandRequest = {
  readonly command: WorkflowRunnableCommand
  readonly script: WorkflowScriptRef
  readonly args: JsonValue
  readonly provider: ProviderSelection
  readonly approval: ApprovalPosture
  readonly requestedRunId: RequestedRunId
  readonly journal: { readonly t: "none" } | { readonly t: "requested"; readonly path: string }
  readonly noInput: boolean
  readonly quiet: boolean
  readonly background: BackgroundLaunchMode
  readonly backgroundWorker: boolean
  readonly options: WorkflowCallOptions
}

export type JournalQueryRequest =
  | { readonly command: "inspect"; readonly journalPath: string; readonly json: boolean }
  | { readonly command: "status"; readonly journalPath: string; readonly eventLimit: number; readonly json: boolean }

export type JournalListRequest = {
  readonly command: "list"
  readonly journalRoot: string
  readonly limit: number
  readonly eventLimit: number
  readonly json: boolean
}

export type ResumeCommandRequest = {
  readonly command: "resume"
  readonly journalPath: string
  readonly provider: ProviderSelection
  readonly approval: ApprovalPosture
  readonly noInput: boolean
  readonly json: boolean
  readonly quiet: boolean
  readonly background: BackgroundLaunchMode
  readonly backgroundWorker: boolean
  readonly options: WorkflowCallOptions
}

export type ServeCommandRequest = {
  readonly command: "serve"
  readonly journalPath: string
  readonly host: string
  readonly port: number
  readonly eventLimit: number
  readonly livePollMs: number
  readonly json: boolean
  readonly quiet: boolean
}

export type ServePortfileRecord = {
  readonly portfilePath: string
  readonly url: string
  readonly pid: number
}

export type DraftCommandRequest = {
  readonly command: "draft"
  readonly goal: string
  readonly name?: string | undefined
  readonly output?: string | undefined
  readonly cwd?: string | undefined
  readonly json: boolean
  readonly quiet: boolean
}

export type DraftWorkflowPlan = {
  readonly workflowName: string
  readonly scriptPath: string
  readonly script: string
  readonly nextSteps: readonly string[]
}

export type JournalPointerTarget = Branded<string, "journal-pointer-target">

export type JournalPointerText =
  | { readonly t: "content" }
  | { readonly t: "pointer"; readonly target: JournalPointerTarget }

export type ProcessExecutionResult = {
  readonly exitCode: number | null
  readonly signal: string | null
  readonly stdout: string
  readonly stderr: string
}

export type WorkflowBudgetName = "small" | "standard" | "deep"

export type WorkflowPhase = {
  readonly title: string
  readonly detail?: string | undefined
  readonly model?: string | undefined
}

export type WorkflowMeta = {
  readonly name: string
  readonly description: string
  readonly whenToUse?: string | undefined
  readonly phases?: readonly WorkflowPhase[] | undefined
}

export type WorkflowCompatibilitySeverity = "error" | "warning" | "info"
export type WorkflowCompatibilityCode =
  | "meta_first"
  | "forbidden_source"
  | "plain_javascript"
  | "meta_literal"
  | "runner_only_helper"
  | "missing_orchestration_hook"

export type WorkflowCompatibilityFinding = {
  readonly severity: WorkflowCompatibilitySeverity
  readonly code: WorkflowCompatibilityCode
  readonly message: string
  readonly line: number
  readonly column: number
  readonly frame: string
  readonly hint?: string | undefined
}

export type WorkflowCompatibilityResult = {
  readonly ok: boolean
  readonly findings: readonly WorkflowCompatibilityFinding[]
}

export type CompatibleWorkflowScript = {
  readonly source: string
  readonly meta: WorkflowMeta
  readonly compatibility: WorkflowCompatibilityResult
}

export type HostAgentOptions = {
  readonly label?: string | undefined
  readonly phase?: string | undefined
  readonly schema?: JsonValue | undefined
  readonly model?: string | undefined
  readonly agentType?: string | undefined
  readonly isolation?: "read-only" | "workspace-write" | "worktree" | "full-access" | undefined
  readonly risk?: string | undefined
}

export type HostPhaseCall = {
  readonly title: string
}

export type HostLogCall = {
  readonly message: string
}

export type HostAgentCall = {
  readonly prompt: string
  readonly options: HostAgentOptions
}

export type HostWorkflowRef =
  | { readonly t: "named"; readonly value: string }
  | { readonly t: "script_path"; readonly scriptPath: string }

export type HostWorkflowCall = {
  readonly ref: HostWorkflowRef
  readonly args: JsonValue
}

export type HostParallelCall = {
  readonly itemCount: number
}

export type HostPipelineCall = {
  readonly itemCount: number
  readonly stageCount: number
}

export type WorkflowChildHostcall =
  | { readonly t: "hostcall"; readonly id: number; readonly op: "phase"; readonly call: HostPhaseCall }
  | { readonly t: "hostcall"; readonly id: number; readonly op: "log"; readonly call: HostLogCall }
  | { readonly t: "hostcall"; readonly id: number; readonly op: "agent"; readonly call: HostAgentCall }
  | { readonly t: "hostcall"; readonly id: number; readonly op: "workflow"; readonly call: HostWorkflowCall }
  | { readonly t: "hostcall"; readonly id: number; readonly op: "parallel"; readonly call: HostParallelCall }
  | { readonly t: "hostcall"; readonly id: number; readonly op: "pipeline"; readonly call: HostPipelineCall }

export type WorkflowChildResult =
  | { readonly t: "done"; readonly value: JsonValue }
  | { readonly t: "failed"; readonly message: string }

export type WorkflowChildMessage = WorkflowChildHostcall | WorkflowChildResult

export type WorkflowChildResponse =
  | { readonly t: "response"; readonly id: number; readonly ok: true; readonly value: JsonValue }
  | { readonly t: "response"; readonly id: number; readonly ok: false; readonly error: { readonly name: string; readonly message: string } }

export class WorkflowValidationError extends Error {
  readonly result: WorkflowCompatibilityResult

  constructor(message: string, result: WorkflowCompatibilityResult) {
    super(message)
    this.name = "WorkflowValidationError"
    this.result = result
  }
}

export type WorkflowCallOptions = {
  readonly budget?: WorkflowBudgetName | undefined
  readonly workingDirectory?: string | undefined
  readonly defaultModel?: string | undefined
  readonly modelPolicy?: string | undefined
  readonly codexBaseUrl?: string | undefined
  readonly codexPathOverride?: string | undefined
  readonly codexConfig?: CodexConfigObject | undefined
  readonly skipGitRepoCheck: boolean
  readonly deterministicTimestamps: boolean
  readonly echoPrompts: boolean
  readonly workflowPermissionKey?: string | undefined
  readonly turnBudget?: number | undefined
  readonly limits: WorkflowLimits
}

export type CodexConfigValue = string | number | boolean | CodexConfigValue[] | CodexConfigObject
export type CodexConfigObject = {
  [key: string]: CodexConfigValue
}

export type ContainmentPolicy = {
  readonly wallTimeoutMs: number
  readonly idleTimeoutMs: number
}

export type WorkflowChildExecutionPolicy = ContainmentPolicy & {
  readonly maxStdoutBytes: number
  readonly maxStderrBytes: number
}

export type RunnerHeartbeatPolicy = {
  readonly intervalMs: number
}

export type WorkflowTerminalStatus = "done" | "failed" | "killed"
export type WorkflowRunStatus = "queued" | "running" | WorkflowTerminalStatus
export type AgentNodeState = "queued" | "running" | "done" | "failed" | "killed"
export type WorkflowPhaseStatus = "pending" | "running" | "completed" | "failed" | "killed"

export type WorkflowLimits = {
  readonly maxAgents: number
  readonly maxConcurrentAgents: number
  readonly schemaRetryLimit: number
  readonly maxWorkItemsPerAgent: number
  readonly maxInventoryItemsReturned: number
  readonly maxPromptBytesPerAgent: number
  readonly maxMutationFilesPerAgent: number
  readonly maxMutationFilesPerRun: number
  readonly maxParallelItems: number
  readonly maxPipelineItems: number
  readonly maxToolCallsPerAgent?: number
  readonly maxToolCallsPerRun?: number
  readonly taskBudgetTokens?: number
  readonly minRemainingTokensForAgent?: number
}

export type WorkflowPreparationFacts = {
  readonly runId: string
  readonly cwd: string
  readonly scriptSha256: string
}

export type PreparedWorkflowRun = {
  readonly command: WorkflowRunnableCommand
  readonly runId: string
  readonly workflowName: string
  readonly scriptPath: string
  readonly scriptSha256: string
  readonly journalPath: string
  readonly args: JsonValue
  readonly provider: WorkflowProvider
  readonly budgetPlan: JsonValue
  readonly limits: WorkflowLimits
  readonly runtimeContract: JsonValue
  readonly requestedRunId: RequestedRunId
  readonly pointerPath?: string | undefined
  readonly pointerTarget?: string | undefined
}

export type WorkflowExecutionOutcome =
  | {
    readonly status: "done"
    readonly result: JsonValue
  }
  | {
    readonly status: "failed"
    readonly error: string
  }

export type ProviderEvent =
  | { readonly t: "thread_bound"; readonly threadId: string }
  | { readonly t: "message_observed"; readonly text: string }
  | { readonly t: "tool_observed"; readonly name: string; readonly summary: string }
  | { readonly t: "file_mutations_observed"; readonly files: readonly { readonly path: string; readonly operation: string }[] }
  | { readonly t: "usage_observed"; readonly inputTokens: number; readonly outputTokens: number }
  | { readonly t: "provider_failed"; readonly message: string }
  | { readonly t: "unknown_telemetry"; readonly sdkType: string }

export type ThreadBinding =
  | { readonly t: "unbound" }
  | { readonly t: "bound"; readonly threadId: string }

export type ToolObservation =
  | { readonly t: "none" }
  | { readonly t: "observed"; readonly name: string; readonly summary: string }

export type AgentProgressSnapshot = {
  readonly thread: ThreadBinding
  readonly tokens: number
  readonly toolCalls: number
  readonly mutationFiles: readonly string[]
  readonly lastTool: ToolObservation
  readonly lastProgressAtMs: number
}

export type AgentProgressDecision =
  | { readonly t: "commit_thread_binding"; readonly threadId: string }
  | { readonly t: "commit_progress"; readonly next: AgentProgressSnapshot }
  | { readonly t: "ignore_progress"; readonly reason: "unchanged" | "telemetry_only" }

export type WorkflowReplayPlan =
  | { readonly t: "fresh" }
  | {
    readonly t: "resume"
    readonly live: boolean
    readonly mutationFiles: readonly string[]
    readonly phaseLogCursor: number
    readonly phaseLogEvents: readonly Extract<JournalEvent, { readonly t: "phase_entered" | "log_emitted" }>[]
    readonly completedAgents: ReadonlyMap<string, Extract<JournalEvent, { readonly t: "agent_completed" }>>
    readonly resumableAgents: ReadonlyMap<string, Extract<JournalEvent, { readonly t: "agent_started" }>>
    readonly observedTokens: number
    readonly observedToolCalls: number
  }

export type WorkflowChildPlan = {
  readonly w: string
  readonly name: string
  readonly ref: HostWorkflowRef
  readonly args: JsonValue
}

export type AgentNodeProjection = {
  readonly id: string
  readonly label: string
  readonly phase?: number | undefined
  readonly phaseTitle?: string | undefined
  readonly state: AgentNodeState
  readonly attempt: number
  readonly promptHash: string
  readonly schemaHash?: string | undefined
  readonly optionsHash: string
  readonly promptPreview: string
  readonly promptFull?: string | undefined
  readonly model?: string | undefined
  readonly effort?: "medium" | "high" | "xhigh" | undefined
  readonly routeReason?: string | undefined
  readonly agentType?: string | undefined
  readonly agentDefinitionSha?: string | undefined
  readonly isolation?: string | undefined
  readonly risk?: string | undefined
  readonly threadId?: string | undefined
  readonly result?: JsonValue | undefined
  readonly error?: string | undefined
  readonly lastToolName?: string | undefined
  readonly lastToolSummary?: string | undefined
  readonly tokens: number
  readonly toolCalls: number
  readonly durationMs: number
}

export type WorkflowPhaseProjection = {
  readonly index: number
  readonly title: string
  readonly status: WorkflowPhaseStatus
  readonly nodes: readonly AgentNodeProjection[]
}

export type RunnerProjection = {
  readonly pid: number
  readonly startedAt?: string | undefined
  readonly lastHeartbeatTs?: string | undefined
}

export type WorkflowSnapshot = {
  readonly schemaVersion: "workflow-snapshot/v2"
  readonly runId: string
  readonly workflowName: string
  readonly status: WorkflowRunStatus
  readonly runner?: RunnerProjection | undefined
  readonly scriptPath: string
  readonly scriptSha256: string
  readonly journalPath: string
  readonly args: JsonValue
  readonly phases: readonly WorkflowPhaseProjection[]
  readonly logs: readonly string[]
  readonly result?: JsonValue | undefined
  readonly error?: string | undefined
  readonly agentCount: number
  readonly totalTokens: number
  readonly totalToolCalls: number
  readonly durationMs?: number | undefined
  readonly budgetPlan?: JsonValue | undefined
  readonly limits?: WorkflowLimits | undefined
  readonly runtimeContract?: JsonValue | undefined
  readonly truncatedTail?: boolean | undefined
}

export type WorkflowStatusSummary = {
  readonly runId: string
  readonly workflowName: string
  readonly status: WorkflowRunStatus
  readonly scriptPath: string
  readonly phaseCount: number
  readonly phases: readonly WorkflowPhaseProjection[]
  readonly nodeCounts: Readonly<Record<AgentNodeState, number>>
  readonly agentCount: number
  readonly totalTokens: number
  readonly totalToolCalls: number
  readonly durationMs?: number | undefined
  readonly runner?: RunnerProjection | undefined
  readonly budgetPlan?: JsonValue | undefined
  readonly runtimeContract?: JsonValue | undefined
  readonly result?: JsonValue | undefined
  readonly error?: string | undefined
  readonly lastEvents: readonly JournalEvent[]
  readonly truncatedTail?: boolean | undefined
}

export type WorkflowListEntry = Partial<WorkflowStatusSummary> & {
  readonly journalPath: string
  readonly updatedAt: string
  readonly error?: string | undefined
}

export type JournalFileCandidate = {
  readonly path: string
  readonly updatedAt: string
}

export type GitWorktreeFacts =
  | { readonly t: "not_repo" }
  | { readonly t: "repo"; readonly root: string; readonly dirty: boolean }

export type RunProjectionState = {
  readonly runId: string
  readonly workflowName: string
  readonly scriptPath: string
  readonly scriptSha256: string
  readonly args: JsonValue
  readonly provider: WorkflowProvider
  readonly budgetPlan?: JsonValue | undefined
  readonly limits?: WorkflowLimits | undefined
  readonly runtimeContract?: JsonValue | undefined
  readonly status: WorkflowRunStatus
  readonly runner?: RunnerProjection | undefined
  readonly phases: readonly {
    readonly index: number
    readonly title: string
    readonly status: WorkflowPhaseStatus
    readonly nodeIds: readonly string[]
  }[]
  readonly nodes: ReadonlyMap<string, AgentNodeProjection>
  readonly logs: readonly string[]
  readonly totals: {
    readonly agentCount: number
    readonly totalTokens: number
    readonly totalToolCalls: number
  }
  readonly result?: JsonValue | undefined
  readonly error?: string | undefined
  readonly durationMs?: number | undefined
  readonly lastSeq: number
  readonly truncatedTail?: boolean | undefined
}

export type JournalEventDraft =
  | {
    readonly t: "run_opened"
    readonly schema: "agent-loops/journal@2"
    readonly runId: string
    readonly workflowName: string
    readonly scriptPath: string
    readonly scriptSha256: string
    readonly args: JsonValue
    readonly provider: WorkflowProvider
    readonly budgetPlan: JsonValue
    readonly limits: WorkflowLimits
    readonly runtimeContract: JsonValue
  }
  | {
    readonly t: "runner_attached"
    readonly pid: number
    readonly startedAt?: string | undefined
    readonly mode: "fresh" | "resume"
    readonly cliVersion: string
  }
  | {
    readonly t: "runner_heartbeat"
    readonly pid: number
  }
  | {
    readonly t: "phase_entered"
    readonly phase: number
    readonly title: string
    readonly w?: string
  }
  | {
    readonly t: "log_emitted"
    readonly message: string
    readonly w?: string
  }
  | {
    readonly t: "agent_scheduled"
    readonly node: string
    readonly label: string
    readonly phase?: number
    readonly phaseTitle?: string
    readonly attempt: number
    readonly promptHash: string
    readonly schemaHash?: string
    readonly optionsHash: string
    readonly promptPreview: string
    readonly promptFull?: string
    readonly model?: string
    readonly effort: "medium" | "high" | "xhigh"
    readonly routeReason?: string
    readonly agentType?: string
    readonly agentDefinitionSha?: string
    readonly isolation?: string
    readonly risk?: string
    readonly w?: string
  }
  | {
    readonly t: "agent_started"
    readonly node: string
    readonly attempt: number
    readonly threadId?: string
    readonly w?: string
  }
  | {
    readonly t: "agent_completed"
    readonly node: string
    readonly attempt: number
    readonly threadId?: string
    readonly result: JsonValue
    readonly tokens: number
    readonly toolCalls: number
    readonly durationMs: number
    readonly source: "provider-schema" | "text" | "mock"
    readonly w?: string
  }
  | {
    readonly t: "agent_progress"
    readonly node: string
    readonly attempt: number
    readonly tokens?: number
    readonly toolCalls?: number
    readonly lastToolName?: string
    readonly lastToolSummary?: string
    readonly w?: string
  }
  | {
    readonly t: "agent_retried"
    readonly node: string
    readonly attempt: number
    readonly reason: "schema-invalid" | "output-unparseable"
    readonly errors: readonly string[]
    readonly w?: string
  }
  | {
    readonly t: "agent_failed"
    readonly node: string
    readonly attempt: number
    readonly error: { readonly name: string; readonly kind: "config" | "malformed-output" | "budget" | "aborted" | "provider"; readonly message: string }
    readonly tokens?: number
    readonly toolCalls?: number
    readonly durationMs?: number
    readonly w?: string
  }
  | {
    readonly t: "agent_replayed"
    readonly node: string
    readonly attempt: number
    readonly w?: string
  }
  | {
    readonly t: "child_started"
    readonly w: string
    readonly name: string
  }
  | {
    readonly t: "child_finished"
    readonly w: string
    readonly status: WorkflowTerminalStatus
    readonly result?: JsonValue | undefined
  }
  | {
    readonly t: "script_changed"
    readonly scriptSha256: string
  }
  | {
    readonly t: "run_finished"
    readonly status: "done" | "failed" | "killed"
    readonly result?: JsonValue | undefined
    readonly error?: string | undefined
    readonly totalTokens: number
    readonly totalToolCalls: number
    readonly durationMs: number
  }

export type CommittedJournalEvent = {
  readonly seq: number
  readonly event: JournalEvent
}

export type JournalCommitRequest = {
  readonly idempotencyKey: string
  readonly event: JournalEventDraft
}

export type JournalMutationRecord = {
  readonly node: string
  readonly attempt: number
  readonly files: readonly string[]
}

export type JournalEventBase = {
  readonly seq: number
  readonly ts?: string
  readonly w?: string
}

export type JournalEvent =
  | (JournalEventBase & {
    readonly t: "run_opened"
    readonly schema: "agent-loops/journal@2"
    readonly runId: string
    readonly workflowName: string
    readonly scriptPath: string
    readonly scriptSha256: string
    readonly args: JsonValue
    readonly provider: WorkflowProvider
    readonly budgetPlan: JsonValue
    readonly limits: WorkflowLimits
    readonly runtimeContract: JsonValue
  })
  | (JournalEventBase & { readonly t: "runner_attached"; readonly pid: number; readonly startedAt?: string; readonly mode: "fresh" | "resume"; readonly cliVersion: string })
  | (JournalEventBase & { readonly t: "runner_heartbeat"; readonly pid: number })
  | (JournalEventBase & { readonly t: "runner_detached"; readonly reason: "stale-takeover" })
  | (JournalEventBase & { readonly t: "phase_entered"; readonly phase: number; readonly title: string })
  | (JournalEventBase & { readonly t: "log_emitted"; readonly message: string })
  | (JournalEventBase & {
    readonly t: "agent_scheduled"
    readonly node: string
    readonly label: string
    readonly phase?: number
    readonly phaseTitle?: string
    readonly attempt: number
    readonly promptHash: string
    readonly schemaHash?: string
    readonly optionsHash: string
    readonly promptPreview: string
    readonly promptFull?: string
    readonly model?: string
    readonly effort: "medium" | "high" | "xhigh"
    readonly routeReason?: string
    readonly agentType?: string
    readonly agentDefinitionSha?: string
    readonly isolation?: string
    readonly risk?: string
  })
  | (JournalEventBase & { readonly t: "agent_started"; readonly node: string; readonly attempt: number; readonly threadId?: string })
  | (JournalEventBase & {
    readonly t: "agent_progress"
    readonly node: string
    readonly attempt: number
    readonly tokens?: number
    readonly toolCalls?: number
    readonly lastToolName?: string
    readonly lastToolSummary?: string
  })
  | (JournalEventBase & { readonly t: "agent_retried"; readonly node: string; readonly attempt: number; readonly reason: "schema-invalid" | "output-unparseable"; readonly errors: readonly string[] })
  | (JournalEventBase & {
    readonly t: "agent_completed"
    readonly node: string
    readonly attempt: number
    readonly threadId?: string
    readonly result: JsonValue
    readonly tokens: number
    readonly toolCalls: number
    readonly durationMs: number
    readonly source: "provider-schema" | "text" | "mock"
  })
  | (JournalEventBase & {
    readonly t: "agent_failed"
    readonly node: string
    readonly attempt: number
    readonly error: { readonly name: string; readonly kind: "config" | "malformed-output" | "budget" | "aborted" | "provider"; readonly message: string }
    readonly tokens?: number
    readonly toolCalls?: number
    readonly durationMs?: number
  })
  | (JournalEventBase & { readonly t: "agent_replayed"; readonly node: string; readonly attempt: number })
  | (JournalEventBase & { readonly t: "child_started"; readonly w: string; readonly name: string })
  | (JournalEventBase & { readonly t: "child_finished"; readonly w: string; readonly status: WorkflowTerminalStatus; readonly result?: JsonValue | undefined })
  | (JournalEventBase & { readonly t: "script_changed"; readonly scriptSha256: string })
  | (JournalEventBase & {
    readonly t: "run_finished"
    readonly status: WorkflowTerminalStatus
    readonly result?: JsonValue | undefined
    readonly error?: string | undefined
    readonly totalTokens: number
    readonly totalToolCalls: number
    readonly durationMs: number
  })

export type JournalReadResult = {
  readonly opened: Extract<JournalEvent, { readonly t: "run_opened" }>
  readonly events: readonly JournalEvent[]
  readonly truncatedTail: boolean
}

export type WorkflowApiResult =
  | { readonly status: "not_ready"; readonly command: CommandName }
  | { readonly status: "accepted"; readonly command: CommandName }
  | {
    readonly status: "drafted"
    readonly command: "draft"
    readonly workflowName: string
    readonly scriptPath: string
    readonly validation: WorkflowCompatibilityResult
    readonly nextSteps: readonly string[]
  }
  | { readonly status: "validated"; readonly command: "validate"; readonly workflowName: string; readonly scriptPath: string; readonly compatibility: WorkflowCompatibilityResult }
  | {
    readonly status: "completed"
    readonly command: WorkflowRunnableCommand
    readonly snapshot: WorkflowSnapshot
    readonly budgetPlan: JsonValue
    readonly journalPath: string
    readonly scriptPath: string
  }
  | { readonly status: "inspected"; readonly snapshot: WorkflowSnapshot }
  | { readonly status: "summarized"; readonly summary: WorkflowStatusSummary }
  | { readonly status: "listed"; readonly workflows: readonly WorkflowListEntry[] }
  | {
    readonly status: "async_launched"
    readonly command: WorkflowRunnableCommand
    readonly workflowName: string
    readonly pid: number
    readonly runId: string
    readonly journalPath: string
    readonly scriptPath: string
    readonly statusUrl?: string | undefined
    readonly statusServerPid?: number | undefined
  }
