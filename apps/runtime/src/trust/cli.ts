import { z } from "zod"

import type { Proven } from "../domain/brand.ts"
import type { CliRequest, WorkflowApiResult } from "../domain/contracts.ts"
import { COMMANDS, FLAG_TYPES } from "../domain/cli-contract.ts"
import { CliUsageError } from "./cli-error.ts"
import { jsonValueSchema } from "./json.ts"
import { proven } from "./proven.ts"

const commandNames = COMMANDS.map((command) => command.name) as [
  "draft",
  "validate",
  "test",
  "workflow",
  "run",
  "resume",
  "inspect",
  "status",
  "list",
  "serve",
  "help",
]

const flagValueSchema = z.union([z.string(), z.boolean()])
const runStatusSchema = z.enum(["queued", "running", "done", "failed", "killed"])
const phaseStatusSchema = z.enum(["pending", "running", "completed", "failed", "killed"])
const nodeStateSchema = z.enum(["queued", "running", "done", "failed", "killed"])
const effortSchema = z.enum(["medium", "high", "xhigh"])
const compatibilityFindingSchema = z.object({
  severity: z.enum(["error", "warning", "info"]),
  code: z.enum(["meta_first", "forbidden_source", "plain_javascript", "meta_literal", "runner_only_helper", "missing_orchestration_hook"]),
  message: z.string(),
  line: z.number().int().positive(),
  column: z.number().int().positive(),
  frame: z.string(),
  hint: z.string().optional(),
}).strict()
const compatibilitySchema = z.object({
  ok: z.boolean(),
  findings: z.array(compatibilityFindingSchema),
}).strict()
const runnerSchema = z.object({
  pid: z.number().int().positive(),
  startedAt: z.string().optional(),
  lastHeartbeatTs: z.string().optional(),
}).strict()
const nodeSchema = z.object({
  id: z.string(),
  label: z.string(),
  phase: z.number().int().optional(),
  phaseTitle: z.string().optional(),
  state: nodeStateSchema,
  attempt: z.number().int().positive(),
  promptHash: z.string(),
  schemaHash: z.string().optional(),
  optionsHash: z.string(),
  promptPreview: z.string(),
  promptFull: z.string().optional(),
  model: z.string().optional(),
  effort: effortSchema.optional(),
  routeReason: z.string().optional(),
  agentType: z.string().optional(),
  agentDefinitionSha: z.string().optional(),
  isolation: z.string().optional(),
  risk: z.string().optional(),
  threadId: z.string().optional(),
  result: jsonValueSchema.optional(),
  error: z.string().optional(),
  lastToolName: z.string().optional(),
  lastToolSummary: z.string().optional(),
  tokens: z.number().int().nonnegative(),
  toolCalls: z.number().int().nonnegative(),
  durationMs: z.number().finite().nonnegative(),
}).strict()
const phaseSchema = z.object({
  index: z.number().int(),
  title: z.string(),
  status: phaseStatusSchema,
  nodes: z.array(nodeSchema),
}).strict()
const snapshotSchema = z.object({
  schemaVersion: z.literal("workflow-snapshot/v2"),
  runId: z.string(),
  workflowName: z.string(),
  status: runStatusSchema,
  runner: runnerSchema.optional(),
  scriptPath: z.string(),
  scriptSha256: z.string(),
  journalPath: z.string(),
  args: jsonValueSchema,
  phases: z.array(phaseSchema),
  logs: z.array(z.string()),
  result: jsonValueSchema.optional(),
  error: z.string().optional(),
  agentCount: z.number().int().nonnegative(),
  totalTokens: z.number().int().nonnegative(),
  totalToolCalls: z.number().int().nonnegative(),
  durationMs: z.number().finite().nonnegative().optional(),
  budgetPlan: jsonValueSchema.optional(),
  limits: jsonValueSchema.optional(),
  runtimeContract: jsonValueSchema.optional(),
  truncatedTail: z.boolean().optional(),
}).strict()
const statusSummarySchema = z.object({
  runId: z.string(),
  workflowName: z.string(),
  status: runStatusSchema,
  scriptPath: z.string(),
  phaseCount: z.number().int().nonnegative(),
  phases: z.array(phaseSchema),
  nodeCounts: z.record(z.string(), z.number().int().nonnegative()),
  agentCount: z.number().int().nonnegative(),
  totalTokens: z.number().int().nonnegative(),
  totalToolCalls: z.number().int().nonnegative(),
  durationMs: z.number().finite().nonnegative().optional(),
  runner: runnerSchema.optional(),
  budgetPlan: jsonValueSchema.optional(),
  runtimeContract: jsonValueSchema.optional(),
  result: jsonValueSchema.optional(),
  error: z.string().optional(),
  lastEvents: z.array(jsonValueSchema),
  truncatedTail: z.boolean().optional(),
}).strict()
const workflowListEntrySchema = statusSummarySchema.partial().extend({
  journalPath: z.string(),
  updatedAt: z.string(),
  error: z.string().optional(),
}).strict()
const internalWorkflowApiResultSchema = z.discriminatedUnion("status", [
  z.object({ status: z.literal("not_ready"), command: z.enum(commandNames) }).strict(),
  z.object({ status: z.literal("accepted"), command: z.enum(commandNames) }).strict(),
  z.object({
    status: z.literal("drafted"),
    command: z.literal("draft"),
    workflowName: z.string(),
    scriptPath: z.string(),
    validation: compatibilitySchema,
    nextSteps: z.array(z.string()),
  }).strict(),
  z.object({
    status: z.literal("validated"),
    command: z.literal("validate"),
    workflowName: z.string(),
    scriptPath: z.string(),
    compatibility: compatibilitySchema,
  }).strict(),
  z.object({
    status: z.literal("completed"),
    command: z.enum(["resume", "run", "test", "validate", "workflow"]),
    snapshot: snapshotSchema,
    budgetPlan: jsonValueSchema,
    journalPath: z.string(),
    scriptPath: z.string(),
  }).strict(),
  z.object({ status: z.literal("inspected"), snapshot: snapshotSchema }).strict(),
  z.object({ status: z.literal("summarized"), summary: statusSummarySchema }).strict(),
  z.object({ status: z.literal("listed"), workflows: z.array(workflowListEntrySchema) }).strict(),
  z.object({
    status: z.literal("async_launched"),
    command: z.enum(["resume", "run", "test", "validate", "workflow"]),
    workflowName: z.string(),
    pid: z.number().int().nonnegative(),
    runId: z.string(),
    journalPath: z.string(),
    scriptPath: z.string(),
    statusUrl: z.string().url().optional(),
    statusServerPid: z.number().int().nonnegative().optional(),
  }).strict(),
])
const cliEnvelopeSchema = z.union([
  z.object({
    command: z.enum(["resume", "run", "test", "workflow"]),
    snapshot: snapshotSchema,
    budgetPlan: jsonValueSchema,
    journalPath: z.string(),
    scriptPath: z.string(),
  }).strict(),
  z.object({
    command: z.literal("validate"),
    workflowName: z.string(),
    scriptPath: z.string(),
    validation: compatibilitySchema,
  }).strict(),
  z.object({
    command: z.literal("draft"),
    workflowName: z.string(),
    scriptPath: z.string(),
    validation: compatibilitySchema,
    nextSteps: z.array(z.string()),
  }).strict(),
  z.object({ command: z.literal("inspect"), snapshot: snapshotSchema }).strict(),
  z.object({ command: z.literal("status"), status: statusSummarySchema }).strict(),
  z.object({ command: z.literal("list"), workflows: z.array(workflowListEntrySchema) }).strict(),
  z.object({ command: z.literal("serve"), journalPath: z.string(), url: z.string().url() }).strict(),
  z.object({
    command: z.enum(["resume", "run", "test", "validate", "workflow"]),
    status: z.literal("async_launched"),
    workflowName: z.string(),
    pid: z.number().int().nonnegative(),
    runId: z.string(),
    journalPath: z.string(),
    scriptPath: z.string(),
    statusUrl: z.string().url().optional(),
    statusServerPid: z.number().int().nonnegative().optional(),
  }).strict(),
])

const cliRequestSchema = z.object({
  command: z.enum(commandNames),
  args: z.array(z.string()),
  flags: z.record(z.string(), flagValueSchema),
}).strict()

export function parseCliRequest(input: unknown): Proven<CliRequest> {
  const request = cliRequestSchema.parse(input)
  const spec = commandSpec(request.command)
  if (request.args.length > spec.maxPositionals) {
    throw new CliUsageError(`${request.command} accepts at most ${spec.maxPositionals} positional argument(s)`)
  }
  for (const [name, value] of Object.entries(request.flags)) {
    if (!spec.flags.includes(name)) throw new CliUsageError(`${request.command} does not accept --${name}`)
    const expected = FLAG_TYPES.get(name)
    if (expected === undefined) throw new CliUsageError(`unknown flag type for --${name}`)
    if (expected === "boolean" && value !== true) throw new CliUsageError(`--${name} is a boolean flag`)
    if (expected === "string" && typeof value !== "string") throw new CliUsageError(`--${name} requires a value`)
  }
  return proven(request)
}

export function parseCliArgv(argv: readonly string[]): Proven<CliRequest> {
  const command = argv[0] ?? "help"
  const tokens = argv.slice(1)
  const args: string[] = []
  const flags: Record<string, string | boolean> = {}
  let index = 0

  while (index < tokens.length) {
    const token = tokens[index]
    if (token === undefined) break
    if (!token.startsWith("--")) {
      args.push(token)
      index += 1
      continue
    }

    const body = token.slice(2)
    if (body.length < 1) throw new CliUsageError("CLI flag name cannot be empty")
    const equalsIndex = body.indexOf("=")
    if (equalsIndex >= 0) {
      const name = body.slice(0, equalsIndex)
      const value = body.slice(equalsIndex + 1)
      if (name.length < 1) throw new CliUsageError("CLI flag name cannot be empty")
      if (FLAG_TYPES.get(name) === "boolean") throw new CliUsageError(`--${name} is a boolean flag`)
      flags[name] = value
      index += 1
      continue
    }

    const next = tokens[index + 1]
    if (FLAG_TYPES.get(body) === "string") {
      if (next === undefined || next.startsWith("--")) throw new CliUsageError(`--${body} requires a value`)
      flags[body] = next
      index += 2
      continue
    }

    flags[body] = true
    index += 1
  }

  return parseCliRequest({ command, args, flags })
}

function commandSpec(command: CliRequest["command"]) {
  const spec = COMMANDS.find((entry) => entry.name === command)
  if (spec === undefined) throw new CliUsageError(`unknown command ${command}`)
  return spec
}

export function parseWorkflowApiResult(input: unknown): Proven<WorkflowApiResult> {
  return proven(internalWorkflowApiResultSchema.parse(input) as WorkflowApiResult)
}

export function parseWorkflowCliEnvelope(input: unknown): Proven<z.infer<typeof cliEnvelopeSchema>> {
  return proven(cliEnvelopeSchema.parse(input))
}
