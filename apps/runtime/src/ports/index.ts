import type {
  CommittedJournalEvent,
  CompatibleWorkflowScript,
  DraftWorkflowPlan,
  JournalCommitRequest,
  JournalRunCandidate,
  JournalEventDraft,
  JournalMutationRecord,
  PreparedWorkflowRun,
  ProviderEvent,
  ProcessExecutionResult,
  ServeSessionRecord,
  CodexConfigObject,
  WorkflowChildPlan,
  WorkflowCommandRequest,
  WorkflowExecutionOutcome,
  WorkflowPreparationFacts,
  WorkflowProvider,
  WorkflowReplayPlan,
} from "../domain/contracts.ts"
import type { Proven } from "../domain/brand.ts"
import type { JsonValue } from "../domain/json.ts"

export type UntrustedProviderStreamEvent = {
  readonly value: unknown
}

export type ProviderAgentTurnRequest = {
  readonly prompt: string
  readonly schema?: JsonValue | undefined
  readonly model?: string | undefined
  readonly effort: "medium" | "high" | "xhigh"
  readonly isolation?: "read-only" | "workspace-write" | "worktree" | "full-access" | undefined
  readonly threadId?: string | undefined
  readonly workingDirectory?: string | undefined
  readonly skipGitRepoCheck: boolean
  readonly codexBaseUrl?: string | undefined
  readonly codexPathOverride?: string | undefined
  readonly codexConfig?: CodexConfigObject | undefined
  readonly callerSignal: AbortSignal
  readonly onStreamEvent: (event: UntrustedProviderStreamEvent) => Promise<void>
}

export type ProviderAgentTurnOutput = {
  readonly events: readonly UntrustedProviderStreamEvent[]
  readonly durationMs: number
}

export interface ClockPort {
  nowMs(): number
}

export interface JournalStore {
  commit(request: JournalCommitRequest): Promise<CommittedJournalEvent>
  initializeRun(run: PreparedWorkflowRun): Promise<CommittedJournalEvent>
  heartbeat(input: { readonly pid: number }): Promise<CommittedJournalEvent>
  recordMutationFiles(input: { readonly idempotencyKey: string; readonly mutation: JournalMutationRecord }): Promise<void>
  release(): Promise<void>
}

export interface JournalStoreFactory {
  open(run: PreparedWorkflowRun): JournalStore
}

export interface JournalReader {
  resolveRun(input: { readonly runId: string }): Promise<{ readonly runId: string; readonly databasePath: string }>
  readText(runId: string): Promise<string>
  readMutationText(runId: string): Promise<string>
}

export interface JournalDirectoryPort {
  listRuns(): Promise<readonly JournalRunCandidate[]>
}

export interface ProviderTurnPort {
  run(): AsyncIterable<ProviderEvent>
}

export interface ProviderAgentTurnPort {
  runAgentTurn(request: ProviderAgentTurnRequest): Promise<ProviderAgentTurnOutput>
}

export interface ProcessPort {
  pid(): number
  cwd(): string
  probePid(pid: number): void
}

export interface DraftWorkflowStore {
  writeDraft(plan: DraftWorkflowPlan): Promise<{ readonly scriptPath: string }>
}

export interface ServeSessionStore {
  writeSession(record: ServeSessionRecord): Promise<void>
  readSession(runId: string): Promise<string>
  removeSession(runId: string): Promise<void>
}

export interface StatusServerPort {
  start(input: {
    readonly host: string
    readonly port: number
    readonly livePollMs: number
    readonly loadPayload: () => Promise<{
      readonly compactPayload: string
      readonly prettyPayload: string
    }>
    readonly parseRoute: (url: unknown) => StatusServerRoute
    readonly ui: {
      readonly rootDirectory: string
    }
  }): Promise<{
    readonly address: string | object | null
    readonly close: () => Promise<void>
  }>
}

export type StatusServerRoute =
  | { readonly t: "status-json" }
  | { readonly t: "events" }
  | { readonly t: "asset"; readonly path: string }
  | { readonly t: "index" }
  | { readonly t: "not-found" }

export interface BackgroundProcessLauncher {
  launchResumeWorker(input: { readonly runId: string }): Promise<{ readonly pid: number }>
  launchStatusServer(input: { readonly runId: string; readonly host: string; readonly port: number }): Promise<{ readonly pid: number }>
  terminate(input: { readonly pid: number }): Promise<void>
  wait(input: { readonly ms: number }): Promise<void>
}

export interface RunnerHeartbeatPort {
  start(input: { readonly writeHeartbeat: () => Promise<void> }): Promise<{ readonly stop: () => Promise<void> }>
}

export interface GitPort {
  probeRoot(cwd: string): Promise<ProcessExecutionResult>
  probeStatus(cwd: string): Promise<ProcessExecutionResult>
}

export interface WorkflowRunPreparer {
  prepare(input: {
    readonly script: Proven<CompatibleWorkflowScript>
  }): Promise<WorkflowPreparationFacts>
}

export interface WorkflowScriptLocator {
  locate(request: Proven<WorkflowCommandRequest>): Promise<string>
}

export interface WorkflowScriptSourceStore {
  read(path: string): Promise<string>
}

export interface WorkflowChildResolver {
  resolveChild(plan: WorkflowChildPlan): Promise<{
    readonly scriptPath: string
    readonly source: string
    readonly args: WorkflowChildPlan["args"]
  }>
}

export interface WorkflowExecutor {
  execute(input: {
    readonly request: WorkflowCommandRequest
    readonly run: PreparedWorkflowRun
    readonly script: Proven<CompatibleWorkflowScript>
    readonly replay: WorkflowReplayPlan
    readonly emit: (event: JournalEventDraft) => Promise<void>
    readonly recordMutationFiles: (record: JournalMutationRecord) => Promise<void>
  }): Promise<WorkflowExecutionOutcome>
}
