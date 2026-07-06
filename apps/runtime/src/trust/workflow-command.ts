import { z } from "zod"

import type { Proven } from "../domain/brand.ts"
import type {
  ApprovalPosture,
  CliRequest,
  CodexConfigValue,
  ProviderSelection,
  RequestedRunId,
  WorkflowCommandRequest,
  WorkflowBudgetName,
  WorkflowLimits,
  WorkflowProvider,
  WorkflowRunnableCommand,
  WorkflowScriptRef,
  BackgroundLaunchMode,
} from "../domain/contracts.ts"
import { CliUsageError } from "./cli-error.ts"
import { jsonValueSchema } from "./json.ts"
import { proven } from "./proven.ts"

const runnableCommandSchema = z.enum(["resume", "run", "test", "validate", "workflow"])
const providerSchema = z.enum(["mock", "sdk"])
const flagValueSchema = z.union([z.string(), z.boolean()])
const budgetSchema = z.enum(["small", "standard", "deep"])
const DEFAULT_BACKGROUND_HANDSHAKE_POLL_MS = 50
const DEFAULT_BACKGROUND_HANDSHAKE_MAX_POLLS = 40
const DEFAULT_STATUS_HOST = "127.0.0.1"
const DEFAULT_STATUS_PORT = 0
const DEFAULT_STATUS_SESSION_POLL_MS = 50
const DEFAULT_STATUS_SESSION_MAX_POLLS = 40
const DEFAULT_WORKFLOW_LIMITS: WorkflowLimits = {
  maxAgents: 1000,
  maxConcurrentAgents: 8,
  schemaRetryLimit: 2,
  maxWorkItemsPerAgent: 4096,
  maxInventoryItemsReturned: 4096,
  maxPromptBytesPerAgent: 16_000,
  maxMutationFilesPerAgent: 1,
  maxMutationFilesPerRun: 12,
  maxParallelItems: 4096,
  maxPipelineItems: 4096,
}
const WORKFLOW_BUDGET_LIMITS: Record<WorkflowBudgetName, WorkflowLimits> = {
  small: {
    ...DEFAULT_WORKFLOW_LIMITS,
    maxAgents: 6,
    maxConcurrentAgents: 2,
    maxWorkItemsPerAgent: 6,
    maxInventoryItemsReturned: 12,
    maxMutationFilesPerRun: 12,
  },
  standard: {
    ...DEFAULT_WORKFLOW_LIMITS,
    maxAgents: 1000,
    maxConcurrentAgents: 8,
  },
  deep: {
    ...DEFAULT_WORKFLOW_LIMITS,
    maxAgents: 1000,
    maxConcurrentAgents: 8,
  },
}
const codexConfigValueSchema: z.ZodType<CodexConfigValue> = z.lazy(() => z.union([
  z.string(),
  z.number().finite(),
  z.boolean(),
  z.array(codexConfigValueSchema),
  z.record(z.string(), codexConfigValueSchema),
]))
const codexConfigSchema = z.record(z.string(), codexConfigValueSchema)
const callOptionsSchema = z.object({
  budget: budgetSchema.optional(),
  provider: providerSchema.optional(),
  journal: z.string().min(1).optional(),
  workingDirectory: z.string().min(1).optional(),
  defaultModel: z.string().min(1).optional(),
  modelPolicy: z.string().min(1).optional(),
  codexBaseUrl: z.string().min(1).optional(),
  codexPathOverride: z.string().min(1).optional(),
  codexConfig: codexConfigSchema.optional(),
  skipGitRepoCheck: z.boolean().default(false),
  deterministicTimestamps: z.boolean().default(false),
  echoPrompts: z.boolean().default(false),
  quiet: z.boolean().default(false),
  noInput: z.boolean().default(false),
  approved: z.boolean().default(false),
  workflowPermissionKey: z.string().min(1).optional(),
  runId: z.string().min(1).optional(),
  background: z.boolean().default(false),
  backgroundWorker: z.boolean().default(false),
  statusServer: z.boolean().default(false),
  statusHost: z.string().min(1).optional(),
  statusPort: z.number().int().min(0).max(65535).optional(),
  turnBudget: z.number().finite().positive().optional(),
  maxAgents: z.number().finite().positive().optional(),
  maxConcurrentAgents: z.number().finite().positive().optional(),
  schemaRetryLimit: z.number().finite().positive().optional(),
  maxWorkItemsPerAgent: z.number().finite().positive().optional(),
  maxInventoryItemsReturned: z.number().finite().positive().optional(),
  maxPromptBytesPerAgent: z.number().finite().positive().optional(),
  maxMutationFilesPerAgent: z.number().finite().positive().optional(),
  maxMutationFilesPerRun: z.number().finite().positive().optional(),
  maxParallelItems: z.number().finite().positive().optional(),
  maxPipelineItems: z.number().finite().positive().optional(),
  maxToolCallsPerAgent: z.number().finite().positive().optional(),
  maxToolCallsPerRun: z.number().finite().positive().optional(),
  taskBudget: z.number().finite().positive().optional(),
  minRemainingTokensForAgent: z.number().finite().positive().optional(),
}).strict()

const workflowCommandApiSchema = z.object({
  script: z.string().min(1).optional(),
  args: jsonValueSchema.default({}),
  journal: z.string().min(1).optional(),
  input: callOptionsSchema.optional(),
}).strict()

export function parseWorkflowCommandApiRequest(command: "test" | "workflow", input: unknown): Proven<WorkflowCommandRequest> {
  const parsed = workflowCommandApiSchema.parse(input)
  rejectRemovedJournal(parsed.journal)
  rejectRemovedJournal(parsed.input?.journal)
  return parsedWorkflowCommandRequest({
    command,
    script: parseScriptSelection(parsed.script),
    args: parsed.args,
    options: parsed.input ?? emptyCallOptions(),
  })
}

export function parseWorkflowProgrammaticCall(
  command: "test" | "workflow",
  nameOrRef: unknown,
  rest: readonly unknown[],
): Proven<WorkflowCommandRequest> {
  const tuple = z.tuple([
    jsonValueSchema.optional(),
    callOptionsSchema.optional(),
    z.object({ signal: z.unknown().optional() }).strict().optional(),
  ]).rest(z.never()).parse(rest)
  const ref = parseProgrammaticRef(nameOrRef)
  const args = tuple[0] ?? {}
  const input = tuple[1] ?? emptyCallOptions()
  rejectRemovedJournal(input.journal)
  return proven({
    command,
    script: ref,
    args,
    provider: parseProviderSelection(command, input.provider),
    approval: parseApproval(input.approved),
    requestedRunId: parseRequestedRunId(input.runId),
    noInput: input.noInput,
    quiet: input.quiet,
    background: parseBackgroundLaunch(input),
    backgroundWorker: input.backgroundWorker,
    options: parseCallOptions(input),
  })
}

export function parseWorkflowCommandCliRequest(input: Proven<CliRequest>): Proven<WorkflowCommandRequest> {
  const command = runnableCommandSchema.parse(input.command)
  const flags = z.record(z.string(), flagValueSchema).parse(input.flags)
  rejectRemovedJournal(parseOptionalString(flags["journal"]))
  const provider = parseCliProvider(flags)
  const args = parseArgsFlag(flags["args"])

  return parsedWorkflowCommandRequest({
    command,
    script: parseScriptSelection(input.args[0]),
    args,
    options: {
      budget: parseBudget(flags["budget"]),
      provider,
      workingDirectory: parseOptionalString(flags["working-directory"]) ?? parseOptionalString(flags["cwd"]),
      defaultModel: parseOptionalString(flags["model"]),
      modelPolicy: parseOptionalString(flags["model-policy"]),
      codexBaseUrl: parseOptionalString(flags["codex-base-url"]),
      codexPathOverride: parseOptionalString(flags["codex-path-override"]),
      codexConfig: parseCodexConfigOption(flags["codex-config"]),
      skipGitRepoCheck: flags["skip-git-repo-check"] === true,
      deterministicTimestamps: flags["deterministic-timestamps"] === true,
      echoPrompts: flags["echo-prompts"] === true,
      quiet: flags["quiet"] === true,
      noInput: flags["no-input"] === true,
      approved: flags["approved"] === true,
      workflowPermissionKey: parseOptionalString(flags["workflow-permission-key"]),
      runId: parseOptionalString(flags["run-id"]),
      background: flags["background"] === true,
      backgroundWorker: flags["background-worker"] === true,
      statusServer: flags["status-server"] === true,
      statusHost: parseOptionalString(flags["status-host"]),
      statusPort: parsePortNumber(flags["status-port"]),
      turnBudget: parsePositiveNumber(flags["task-budget"]),
      taskBudget: parsePositiveNumber(flags["task-budget"]),
      maxAgents: parsePositiveNumber(flags["max-agents"]),
      maxConcurrentAgents: parsePositiveNumber(flags["max-concurrent"]),
      schemaRetryLimit: parsePositiveNumber(flags["schema-retry-limit"]),
      maxWorkItemsPerAgent: parsePositiveNumber(flags["max-work-items-per-agent"]),
      maxInventoryItemsReturned: parsePositiveNumber(flags["max-inventory-items-returned"]),
      maxPromptBytesPerAgent: parsePositiveNumber(flags["max-prompt-bytes-per-agent"]),
      maxMutationFilesPerAgent: parsePositiveNumber(flags["max-mutation-files-per-agent"]),
      maxMutationFilesPerRun: parsePositiveNumber(flags["max-mutation-files-per-run"]),
      maxParallelItems: parsePositiveNumber(flags["max-parallel-items"]),
      maxPipelineItems: parsePositiveNumber(flags["max-pipeline-items"]),
      maxToolCallsPerAgent: parsePositiveNumber(flags["max-tool-calls-per-agent"]),
      maxToolCallsPerRun: parsePositiveNumber(flags["max-tool-calls-per-run"]),
      minRemainingTokensForAgent: parsePositiveNumber(flags["min-remaining-tokens-for-agent"]),
    },
  })
}

function parsedWorkflowCommandRequest(input: {
  command: WorkflowRunnableCommand
  script: WorkflowScriptRef
  args: ReturnType<typeof jsonValueSchema.parse>
  options: z.infer<typeof callOptionsSchema>
}): Proven<WorkflowCommandRequest> {
  return proven({
    command: input.command,
    script: input.script,
    args: input.args,
    provider: parseProviderSelection(input.command, input.options.provider),
    approval: parseApproval(input.options.approved),
    requestedRunId: parseRequestedRunId(input.options.runId),
    noInput: input.options.noInput,
    quiet: input.options.quiet,
    background: parseBackgroundLaunch(input.options),
    backgroundWorker: input.options.backgroundWorker,
    options: parseCallOptions(input.options),
  })
}

function parseScriptSelection(value: string | undefined): WorkflowScriptRef {
  if (value === undefined) return { t: "none" }
  return { t: "unresolved", value }
}

function rejectRemovedJournal(value: string | undefined): void {
  if (value !== undefined) throw new CliUsageError("--journal was removed; use --run-id")
}

function parseRequestedRunId(value: string | undefined): RequestedRunId {
  if (value === undefined) return { t: "none" }
  return { t: "requested", value }
}

function parseApproval(approved: boolean): ApprovalPosture {
  if (approved) return "approved"
  return "not-approved"
}

function parseBackgroundLaunch(input: z.infer<typeof callOptionsSchema>["background"] | z.infer<typeof callOptionsSchema>): BackgroundLaunchMode {
  const background = typeof input === "boolean" ? input : input.background
  if (!background) return { t: "foreground" }
  return {
    t: "launch",
    handshakePollMs: DEFAULT_BACKGROUND_HANDSHAKE_POLL_MS,
    handshakeMaxPolls: DEFAULT_BACKGROUND_HANDSHAKE_MAX_POLLS,
    statusServer: typeof input === "boolean" || !input.statusServer
      ? { t: "disabled" }
      : {
        t: "enabled",
        host: input.statusHost ?? DEFAULT_STATUS_HOST,
        port: input.statusPort ?? DEFAULT_STATUS_PORT,
        sessionPollMs: DEFAULT_STATUS_SESSION_POLL_MS,
        sessionMaxPolls: DEFAULT_STATUS_SESSION_MAX_POLLS,
      },
  }
}

function parseCallOptions(input: z.infer<typeof callOptionsSchema>): WorkflowCommandRequest["options"] {
  return {
    budget: input.budget,
    workingDirectory: input.workingDirectory,
    defaultModel: input.defaultModel,
    modelPolicy: input.modelPolicy,
    codexBaseUrl: input.codexBaseUrl,
    codexPathOverride: input.codexPathOverride,
    codexConfig: input.codexConfig,
    skipGitRepoCheck: input.skipGitRepoCheck,
    deterministicTimestamps: input.deterministicTimestamps,
    echoPrompts: input.echoPrompts,
    workflowPermissionKey: input.workflowPermissionKey,
    turnBudget: input.turnBudget,
    limits: parseWorkflowLimits(input),
  }
}

function emptyCallOptions(): z.infer<typeof callOptionsSchema> {
  return {
    skipGitRepoCheck: false,
    deterministicTimestamps: false,
    echoPrompts: false,
    quiet: false,
    noInput: false,
    approved: false,
    background: false,
    backgroundWorker: false,
    statusServer: false,
  }
}

function parseWorkflowLimits(input: z.infer<typeof callOptionsSchema>): WorkflowLimits {
  const base = workflowLimitsForBudget(input.budget)
  return {
    maxAgents: input.maxAgents ?? base.maxAgents,
    maxConcurrentAgents: input.maxConcurrentAgents ?? base.maxConcurrentAgents,
    schemaRetryLimit: input.schemaRetryLimit ?? base.schemaRetryLimit,
    maxWorkItemsPerAgent: input.maxWorkItemsPerAgent ?? base.maxWorkItemsPerAgent,
    maxInventoryItemsReturned: input.maxInventoryItemsReturned ?? base.maxInventoryItemsReturned,
    maxPromptBytesPerAgent: input.maxPromptBytesPerAgent ?? base.maxPromptBytesPerAgent,
    maxMutationFilesPerAgent: input.maxMutationFilesPerAgent ?? base.maxMutationFilesPerAgent,
    maxMutationFilesPerRun: input.maxMutationFilesPerRun ?? base.maxMutationFilesPerRun,
    maxParallelItems: input.maxParallelItems ?? base.maxParallelItems,
    maxPipelineItems: input.maxPipelineItems ?? base.maxPipelineItems,
    ...(input.maxToolCallsPerAgent === undefined ? optionalNumber("maxToolCallsPerAgent", base.maxToolCallsPerAgent) : { maxToolCallsPerAgent: input.maxToolCallsPerAgent }),
    ...(input.maxToolCallsPerRun === undefined ? optionalNumber("maxToolCallsPerRun", base.maxToolCallsPerRun) : { maxToolCallsPerRun: input.maxToolCallsPerRun }),
    ...(input.taskBudget === undefined ? optionalNumber("taskBudgetTokens", base.taskBudgetTokens) : { taskBudgetTokens: input.taskBudget }),
    ...(input.minRemainingTokensForAgent === undefined ? optionalNumber("minRemainingTokensForAgent", base.minRemainingTokensForAgent) : { minRemainingTokensForAgent: input.minRemainingTokensForAgent }),
  }
}

function workflowLimitsForBudget(budget: WorkflowBudgetName | undefined): WorkflowLimits {
  if (budget === undefined) return DEFAULT_WORKFLOW_LIMITS
  return WORKFLOW_BUDGET_LIMITS[budget]
}

function optionalNumber<Key extends keyof WorkflowLimits>(key: Key, value: WorkflowLimits[Key]): Pick<WorkflowLimits, Key> | {} {
  return value === undefined ? {} : { [key]: value } as Pick<WorkflowLimits, Key>
}

function parseProviderSelection(command: WorkflowRunnableCommand, provider: WorkflowProvider | undefined): ProviderSelection {
  if (provider !== undefined) {
    if (command === "validate" && provider !== "mock") throw new CliUsageError("validate requires provider mock")
    return { t: "explicit", provider }
  }
  if (command === "test" || command === "validate") return { t: "default_for_command", fallback: "mock" }
  return { t: "default_for_command", fallback: "sdk" }
}

function parseOptionalProvider(value: string | boolean | undefined): WorkflowProvider | undefined {
  if (value === undefined) return undefined
  if (value === "mock" || value === "sdk") return value
  throw new CliUsageError("provider must be mock or sdk")
}

function parseCliProvider(flags: Record<string, string | boolean>): WorkflowProvider | undefined {
  const provider = parseOptionalProvider(flags["provider"])
  if (provider !== undefined) return provider
  if (flags["mock"] === true) return "mock"
  return undefined
}

function parseBudget(value: string | boolean | undefined): WorkflowBudgetName | undefined {
  if (value === undefined) return undefined
  if (value === "small" || value === "standard" || value === "deep") return value
  throw new CliUsageError("budget must be small, standard, or deep")
}

function parseOptionalString(value: string | boolean | undefined): string | undefined {
  if (value === undefined) return undefined
  if (typeof value === "string" && value.length > 0) return value
  throw new CliUsageError("expected a non-empty string")
}

function parseArgsFlag(value: string | boolean | undefined) {
  if (value === undefined) return jsonValueSchema.parse({})
  if (typeof value !== "string") throw new CliUsageError("args must be a JSON string")
  return jsonValueSchema.parse(parseJsonText(value, "--args"))
}

function parseJsonOption(value: string | boolean | undefined, flag: string) {
  if (value === undefined) return undefined
  if (typeof value !== "string") throw new CliUsageError(`${flag} must be a JSON string`)
  return jsonValueSchema.parse(parseJsonText(value, flag))
}

function parseCodexConfigOption(value: string | boolean | undefined): z.infer<typeof codexConfigSchema> | undefined {
  if (value === undefined) return undefined
  if (typeof value !== "string") throw new CliUsageError("--codex-config must be a JSON string")
  return codexConfigSchema.parse(parseJsonText(value, "--codex-config"))
}

function parsePositiveNumber(value: string | boolean | undefined): number | undefined {
  if (value === undefined) return undefined
  if (typeof value !== "string") throw new CliUsageError("expected a numeric string")
  const parsed = Number(value)
  if (!Number.isFinite(parsed) || parsed <= 0) throw new CliUsageError("expected a positive number")
  return parsed
}

function parsePortNumber(value: string | boolean | undefined): number | undefined {
  if (value === undefined) return undefined
  if (typeof value !== "string") throw new CliUsageError("expected a port number")
  const parsed = Number(value)
  if (!Number.isInteger(parsed) || parsed < 0 || parsed > 65535) throw new CliUsageError("expected an integer port between 0 and 65535")
  return parsed
}

function parseJsonText(value: string, flag: string): unknown {
  try {
    return JSON.parse(value)
  } catch {
    throw new CliUsageError(`${flag} must be valid JSON`)
  }
}

function parseProgrammaticRef(value: unknown): WorkflowScriptRef {
  if (typeof value === "string" && value.length > 0) return { t: "unresolved", value }
  const parsed = z.object({ scriptPath: z.string().min(1) }).strict().parse(value)
  return { t: "unresolved", value: parsed.scriptPath }
}
