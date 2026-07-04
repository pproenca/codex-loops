import { z } from "zod"

import type { Proven } from "../domain/brand.ts"
import type { JournalEvent, JournalReadResult } from "../domain/contracts.ts"
import { jsonValueSchema } from "./json.ts"
import { proven } from "./proven.ts"

const positiveInt = z.number().int().positive()
const nonNegativeInt = z.number().int().nonnegative()
const nonNegativeNumber = z.number().finite().nonnegative()
const nonEmptyString = z.string().min(1)
const hash32 = z.string().regex(/^[0-9a-f]{32}$/)
const promptPreview = z.string().max(180)

const base = {
  seq: positiveInt,
  ts: z.string().optional(),
  w: z.string().optional(),
}

const workflowLimitsSchema = z.object({
  maxAgents: positiveInt,
  maxConcurrentAgents: positiveInt,
  schemaRetryLimit: positiveInt,
  maxWorkItemsPerAgent: positiveInt,
  maxInventoryItemsReturned: positiveInt,
  maxPromptBytesPerAgent: positiveInt,
  maxMutationFilesPerAgent: positiveInt,
  maxMutationFilesPerRun: positiveInt,
  maxParallelItems: positiveInt,
  maxPipelineItems: positiveInt,
  maxToolCallsPerAgent: positiveInt.optional(),
  maxToolCallsPerRun: positiveInt.optional(),
  taskBudgetTokens: positiveInt.optional(),
  minRemainingTokensForAgent: positiveInt.optional(),
}).strict()

const workloadPlanSchema = z.object({
  scopeKind: z.enum(["bounded", "repo-wide", "unknown"]),
  expectedInputItems: z.number().finite().optional(),
  maxCandidateItems: z.number().finite().optional(),
  maxMutationFilesPerRun: z.number().finite().optional(),
  maxMutationFilesPerAgent: z.number().finite().optional(),
  maxPromptBytesPerAgent: z.number().finite().optional(),
  batchable: z.boolean(),
  runCompleteness: z.enum(["full", "partial", "plan-only"]),
  basis: z.string(),
}).strict()

const budgetPlanSchema = z.object({
  provider: z.enum(["sdk", "mock"]),
  limits: workflowLimitsSchema,
  expectedAgents: z.object({
    minimum: z.number().finite(),
    maximum: z.number().finite(),
    basis: z.string(),
  }).strict(),
  workload: workloadPlanSchema,
  modelPolicySummary: z.object({
    defaultModel: z.string().optional(),
    defaultEffort: z.string(),
    minEffort: z.string(),
    maxEffort: z.string(),
    disallowedEfforts: z.array(z.string()),
  }).strict(),
  writeScope: z.object({
    posture: z.enum(["read-only", "workspace-write", "mixed", "full-access"]),
    summary: z.string(),
  }).strict(),
  tokenWarning: z.string(),
  dollarEstimate: z.object({
    enabled: z.boolean(),
    reason: z.string(),
  }).strict().optional(),
}).strict()

const runtimeContractSchema = z.object({
  activation: z.object({
    allowed: z.boolean(),
    source: z.enum(["cli-command", "programmatic-api", "runner-api"]),
    command: z.string(),
    reason: z.string(),
  }).strict(),
  permission: z.object({
    decision: z.enum(["allow", "caller-owned", "deny"]),
    source: z.string(),
    autoDenied: z.boolean(),
    ruleText: z.string(),
    targetSettingsSource: z.string().optional(),
  }).strict(),
  structuredOutput: z.object({
    mode: z.literal("provider-schema"),
    failClosed: z.literal(true),
    schemaRetryLimit: z.number().finite(),
  }).strict(),
  scheduling: z.object({
    maxAgents: z.number().finite(),
    maxConcurrentAgents: z.number().finite(),
    queueExcessAgents: z.literal(true),
    queueStateVisible: z.literal(true),
    releaseSlotsOnTerminalState: z.literal(true),
  }).strict(),
  budgeting: z.object({
    taskBudgetTokens: z.number().finite().optional(),
    minRemainingTokensForAgent: z.number().finite().optional(),
    accountingFields: z.array(z.string()),
    thresholdPolicy: z.string(),
  }).strict(),
  resume: z.object({
    journalPath: z.string().optional(),
    cacheKey: z.literal("runId+phaseTitle+label+promptHash+schemaHash+optionsHash"),
    completedNodesReplayFromJournal: z.literal(true),
  }).strict(),
  remote: z.object({
    supported: z.literal(false),
    reason: z.string(),
  }).strict(),
}).strict()

const runOpened = z.object({
  ...base,
  t: z.literal("run_opened"),
  schema: z.literal("agent-loops/journal@2"),
  runId: nonEmptyString,
  workflowName: nonEmptyString,
  scriptPath: nonEmptyString,
  scriptSha256: nonEmptyString,
  args: jsonValueSchema,
  provider: z.enum(["sdk", "mock"]),
  budgetPlan: budgetPlanSchema,
  limits: workflowLimitsSchema,
  runtimeContract: runtimeContractSchema,
}).strict()

const runnerAttached = z.object({
  ...base,
  t: z.literal("runner_attached"),
  pid: positiveInt,
  startedAt: z.string().optional(),
  mode: z.enum(["fresh", "resume"]),
  cliVersion: nonEmptyString,
}).strict()

const runnerHeartbeat = z.object({
  ...base,
  t: z.literal("runner_heartbeat"),
  pid: positiveInt,
}).strict()

const runnerDetached = z.object({
  ...base,
  t: z.literal("runner_detached"),
  reason: z.literal("stale-takeover"),
}).strict()

const phaseEntered = z.object({
  ...base,
  t: z.literal("phase_entered"),
  phase: nonNegativeInt,
  title: z.string(),
}).strict()

const logEmitted = z.object({
  ...base,
  t: z.literal("log_emitted"),
  message: z.string(),
}).strict()

const agentScheduled = z.object({
  ...base,
  t: z.literal("agent_scheduled"),
  node: hash32,
  label: nonEmptyString,
  phase: nonNegativeInt.optional(),
  phaseTitle: z.string().optional(),
  attempt: positiveInt,
  promptHash: hash32,
  schemaHash: hash32.optional(),
  optionsHash: hash32,
  promptPreview,
  promptFull: z.string().optional(),
  model: z.string().optional(),
  effort: z.enum(["medium", "high", "xhigh"]),
  routeReason: z.string().optional(),
  agentType: z.string().optional(),
  agentDefinitionSha: z.string().optional(),
  isolation: z.string().optional(),
  risk: z.string().optional(),
}).strict()

const agentStarted = z.object({
  ...base,
  t: z.literal("agent_started"),
  node: hash32,
  attempt: positiveInt,
  threadId: nonEmptyString.optional(),
}).strict()

const agentProgress = z.object({
  ...base,
  t: z.literal("agent_progress"),
  node: hash32,
  attempt: positiveInt,
  tokens: nonNegativeInt.optional(),
  toolCalls: nonNegativeInt.optional(),
  lastToolName: z.string().optional(),
  lastToolSummary: z.string().optional(),
}).strict()

const agentRetried = z.object({
  ...base,
  t: z.literal("agent_retried"),
  node: hash32,
  attempt: positiveInt,
  reason: z.enum(["schema-invalid", "output-unparseable"]),
  errors: z.array(z.string()),
}).strict()

const agentCompleted = z.object({
  ...base,
  t: z.literal("agent_completed"),
  node: hash32,
  attempt: positiveInt,
  threadId: nonEmptyString.optional(),
  result: jsonValueSchema,
  tokens: nonNegativeInt,
  toolCalls: nonNegativeInt,
  durationMs: nonNegativeNumber,
  source: z.enum(["provider-schema", "text", "mock"]),
}).strict()

const agentFailed = z.object({
  ...base,
  t: z.literal("agent_failed"),
  node: hash32,
  attempt: positiveInt,
  error: z.object({
    name: nonEmptyString,
    kind: z.enum(["config", "malformed-output", "budget", "aborted", "provider"]),
    message: z.string(),
  }).strict(),
  tokens: nonNegativeInt.optional(),
  toolCalls: nonNegativeInt.optional(),
  durationMs: nonNegativeNumber.optional(),
}).strict()

const agentReplayed = z.object({
  ...base,
  t: z.literal("agent_replayed"),
  node: hash32,
  attempt: positiveInt,
}).strict()

const childStarted = z.object({
  ...base,
  t: z.literal("child_started"),
  w: nonEmptyString,
  name: nonEmptyString,
}).strict()

const childFinished = z.object({
  ...base,
  t: z.literal("child_finished"),
  w: nonEmptyString,
  status: z.enum(["done", "failed", "killed"]),
  result: jsonValueSchema.optional(),
}).strict()

const scriptChanged = z.object({
  ...base,
  t: z.literal("script_changed"),
  scriptSha256: nonEmptyString,
}).strict()

const runFinished = z.object({
  ...base,
  t: z.literal("run_finished"),
  status: z.enum(["done", "failed", "killed"]),
  result: jsonValueSchema.optional(),
  error: z.string().optional(),
  totalTokens: nonNegativeInt,
  totalToolCalls: nonNegativeInt,
  durationMs: nonNegativeNumber,
}).strict()

const journalEventSchema = z.discriminatedUnion("t", [
  runOpened,
  runnerAttached,
  runnerHeartbeat,
  runnerDetached,
  phaseEntered,
  logEmitted,
  agentScheduled,
  agentStarted,
  agentProgress,
  agentRetried,
  agentCompleted,
  agentFailed,
  agentReplayed,
  childStarted,
  childFinished,
  scriptChanged,
  runFinished,
])

export function parseJournalEvent(input: unknown): Proven<JournalEvent> {
  return proven(journalEventSchema.parse(input) as JournalEvent)
}

export function parseJournalEventLine(line: string): Proven<JournalEvent> {
  return parseJournalEvent(JSON.parse(line))
}

export function parseJournalText(text: string): Proven<JournalReadResult> {
  const endsWithNewline = text.endsWith("\n")
  const rawLines = text.split("\n")
  const completeLines = rawLines.slice(0, -1)
  const events = completeLines.filter((line) => line.length > 0).map((line) => parseJournalEventLine(line))

  if (!endsWithNewline) {
    const tail = rawLines[rawLines.length - 1]
    if (tail !== undefined && tail.length > 0) {
      try {
        events.push(parseJournalEventLine(tail))
        return provenJournalReadResult(events, false)
      } catch {
        return provenJournalReadResult(events, true)
      }
    }
  }

  return provenJournalReadResult(events, false)
}

function provenJournalReadResult(events: readonly JournalEvent[], truncatedTail: boolean): Proven<JournalReadResult> {
  const opened = proveJournalSequence(events)
  return proven({ opened, events, truncatedTail })
}

function proveJournalSequence(events: readonly JournalEvent[]): Extract<JournalEvent, { readonly t: "run_opened" }> {
  let expectedSeq = 1
  let opened: Extract<JournalEvent, { readonly t: "run_opened" }> | undefined
  let terminal = false
  for (const event of events) {
    if (event.seq !== expectedSeq) throw new Error(`journal event out of order: got seq ${event.seq} after seq ${expectedSeq - 1}`)
    if (opened === undefined && event.t !== "run_opened") throw new Error("journal must start with run_opened")
    if (terminal) throw new Error("journal contains events after run_finished")
    if (event.t === "run_opened") {
      if (opened !== undefined) throw new Error("journal contains duplicate run_opened")
      opened = event
    }
    if (event.t === "run_finished") terminal = true
    expectedSeq += 1
  }
  if (opened === undefined) throw new Error("journal must start with run_opened")
  return opened
}
