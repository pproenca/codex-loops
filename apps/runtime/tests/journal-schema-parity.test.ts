import assert from "node:assert/strict"
import { readFile } from "node:fs/promises"
import { test } from "node:test"

import { parseJournalEvent, parseJournalEventLine } from "../src/trust/journal-event.ts"

type JsonSchema = Record<string, unknown>

const limits = {
  maxAgents: 2,
  maxConcurrentAgents: 1,
  schemaRetryLimit: 1,
  maxWorkItemsPerAgent: 3,
  maxInventoryItemsReturned: 4,
  maxPromptBytesPerAgent: 5,
  maxMutationFilesPerAgent: 6,
  maxMutationFilesPerRun: 7,
  maxParallelItems: 8,
  maxPipelineItems: 9,
}

const budgetPlan = {
  provider: "mock",
  limits,
  expectedAgents: { minimum: 1, maximum: 2, basis: "fixture" },
  workload: {
    scopeKind: "bounded",
    expectedInputItems: 1,
    maxCandidateItems: 2,
    maxMutationFilesPerRun: 7,
    maxMutationFilesPerAgent: 6,
    maxPromptBytesPerAgent: 5,
    batchable: false,
    runCompleteness: "full",
    basis: "fixture",
  },
  modelPolicySummary: {
    defaultModel: "model",
    defaultEffort: "medium",
    minEffort: "medium",
    maxEffort: "xhigh",
    disallowedEfforts: [],
  },
  writeScope: { posture: "read-only", summary: "fixture" },
  tokenWarning: "fixture",
  dollarEstimate: { enabled: false, reason: "fixture" },
}

const runtimeContract = {
  activation: { allowed: true, source: "cli-command", command: "test", reason: "fixture" },
  permission: { decision: "allow", source: "fixture", autoDenied: false, ruleText: "fixture", targetSettingsSource: "fixture" },
  structuredOutput: { mode: "provider-schema", failClosed: true, schemaRetryLimit: 1 },
  scheduling: {
    maxAgents: 2,
    maxConcurrentAgents: 1,
    queueExcessAgents: true,
    queueStateVisible: true,
    releaseSlotsOnTerminalState: true,
  },
  budgeting: {
    taskBudgetTokens: 100,
    minRemainingTokensForAgent: 10,
    accountingFields: ["tokens"],
    thresholdPolicy: "fixture",
  },
  resume: {
    cacheKey: "runId+phaseTitle+label+promptHash+schemaHash+optionsHash",
    completedNodesReplayFromJournal: true,
  },
  remote: { supported: false, reason: "fixture" },
}

const nodeId = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
const promptHash = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
const schemaHash = "cccccccccccccccccccccccccccccccc"
const optionsHash = "dddddddddddddddddddddddddddddddd"

const fixtures = [
  {
    seq: 1,
    t: "run_opened",
    schema: "agent-loops/journal@2",
    runId: "run-1",
    workflowName: "wf",
    scriptPath: "/tmp/wf.ts",
    scriptSha256: "abc",
    args: { ticket: 123 },
    provider: "mock",
    budgetPlan,
    limits,
    runtimeContract,
  },
  { seq: 2, t: "runner_attached", pid: 123, startedAt: "2026-06-11T00:00:00.000Z", mode: "fresh", cliVersion: "0.2.0" },
  { seq: 3, t: "runner_heartbeat", pid: 123 },
  { seq: 4, t: "runner_detached", reason: "stale-takeover" },
  { seq: 5, t: "phase_entered", phase: 0, title: "Phase" },
  { seq: 6, t: "log_emitted", message: "hello" },
  {
    seq: 7,
    t: "agent_scheduled",
    node: nodeId,
    label: "Agent",
    phase: 0,
    phaseTitle: "Phase",
    attempt: 1,
    promptHash,
    schemaHash,
    optionsHash,
    promptPreview: "prompt",
    model: "model",
    effort: "medium",
    routeReason: "fixture",
    agentType: "general",
    agentDefinitionSha: "def",
    isolation: "read-only",
    risk: "low",
  },
  { seq: 8, t: "agent_started", node: nodeId, attempt: 1, threadId: "thread-1" },
  { seq: 9, t: "agent_progress", node: nodeId, attempt: 1, tokens: 10, toolCalls: 1, lastToolName: "tool", lastToolSummary: "summary" },
  { seq: 10, t: "agent_retried", node: nodeId, attempt: 1, reason: "schema-invalid", errors: ["bad"] },
  {
    seq: 11,
    t: "agent_completed",
    node: nodeId,
    attempt: 1,
    threadId: "thread-1",
    result: { ok: true },
    tokens: 10,
    toolCalls: 1,
    durationMs: 12,
    source: "mock",
  },
  {
    seq: 12,
    t: "agent_failed",
    node: nodeId,
    attempt: 1,
    error: { name: "AgentError", kind: "provider", message: "failed" },
    tokens: 1,
    toolCalls: 0,
    durationMs: 2,
  },
  { seq: 13, t: "agent_replayed", node: nodeId, attempt: 1 },
  { seq: 14, t: "child_started", w: "child#1", name: "child" },
  { seq: 15, t: "child_finished", w: "child#1", status: "done", result: { ok: true } },
  { seq: 16, t: "script_changed", scriptSha256: "def" },
  { seq: 17, t: "run_finished", status: "done", result: { ok: true }, totalTokens: 10, totalToolCalls: 1, durationMs: 100 },
]

test("journal parser accepts the public-schema fixture corpus and emits schema-compatible records", async () => {
  const schema = await readJournalSchema()

  for (const fixture of fixtures) {
    assert.equal(schemaAccepts(schema, fixture), true, `${fixture.t} fixture must satisfy public schema`)
    const parsed = parseJournalEvent(fixture)
    assert.equal(schemaAccepts(schema, parsed), true, `${fixture.t} parsed record must satisfy public schema`)
  }
})

test("journal parser rejects records rejected by the public schema", async () => {
  const schema = await readJournalSchema()
  const looseBudget = { ...fixtures[0], budgetPlan: { provider: "mock" } }
  const looseRuntime = { ...fixtures[0], runtimeContract: { remote: { supported: false } } }
  const badHash = { ...fixtures[6], node: "node-1" }
  const longPreview = { ...fixtures[6], promptPreview: "x".repeat(181) }
  const unversionedThreadBound = { seq: 18, t: "agent_thread_bound", node: nodeId, attempt: 1, threadId: "thread-1" }

  for (const [index, invalid] of [looseBudget, looseRuntime, badHash, longPreview, unversionedThreadBound].entries()) {
    assert.equal(schemaAccepts(schema, invalid), false, `invalid fixture ${index} must violate public schema`)
    assert.throws(() => parseJournalEventLine(JSON.stringify(invalid)))
  }
})

async function readJournalSchema(): Promise<JsonSchema> {
  return JSON.parse(await readFile(new URL("../schema/journal-event.schema.json", import.meta.url), "utf8")) as JsonSchema
}

function schemaAccepts(schema: JsonSchema, value: unknown): boolean {
  return validateSchema(schema, value, schema).length === 0
}

function validateSchema(schema: unknown, value: unknown, root: JsonSchema): string[] {
  if (!isRecord(schema)) return []
  const ref = schema["$ref"]
  if (typeof ref === "string") return validateSchema(resolveRef(root, ref), value, root)

  const oneOf = schema["oneOf"]
  if (Array.isArray(oneOf)) {
    const matches = oneOf.filter((entry) => validateSchema(entry, value, root).length === 0)
    return matches.length === 1 ? [] : ["oneOf mismatch"]
  }

  const errors: string[] = []
  if ("const" in schema && !Object.is(schema["const"], value)) errors.push("const mismatch")
  if (Array.isArray(schema["enum"]) && !schema["enum"].some((entry) => Object.is(entry, value))) errors.push("enum mismatch")

  const type = schema["type"]
  if (typeof type === "string" && !matchesType(type, value)) errors.push(`type mismatch ${type}`)
  if (typeof schema["minimum"] === "number" && typeof value === "number" && value < schema["minimum"]) errors.push("minimum mismatch")
  if (typeof schema["maxLength"] === "number" && typeof value === "string" && value.length > schema["maxLength"]) errors.push("maxLength mismatch")
  if (typeof schema["pattern"] === "string" && typeof value === "string" && !new RegExp(schema["pattern"]).test(value)) errors.push("pattern mismatch")

  if (isObjectSchema(schema)) {
    if (!isRecord(value)) return [...errors, "object mismatch"]
    const properties = isRecord(schema["properties"]) ? schema["properties"] : {}
    const required = Array.isArray(schema["required"]) ? schema["required"] : []
    for (const key of required) {
      if (typeof key === "string" && !(key in value)) errors.push(`missing ${key}`)
    }
    for (const [key, propertySchema] of Object.entries(properties)) {
      if (key in value) errors.push(...validateSchema(propertySchema, value[key], root).map((error) => `${key}.${error}`))
    }
    if (schema["additionalProperties"] === false) {
      const allowed = new Set(Object.keys(properties))
      for (const key of Object.keys(value)) {
        if (!allowed.has(key)) errors.push(`extra ${key}`)
      }
    }
  }

  if (type === "array" || "items" in schema) {
    if (!Array.isArray(value)) return [...errors, "array mismatch"]
    for (const entry of value) errors.push(...validateSchema(schema["items"], entry, root))
  }

  return errors
}

function resolveRef(root: JsonSchema, ref: string): unknown {
  const path = ref.replace(/^#\//, "").split("/")
  let current: unknown = root
  for (const segment of path) {
    if (!isRecord(current)) return {}
    current = current[segment]
  }
  return current
}

function isObjectSchema(schema: JsonSchema): boolean {
  return schema["type"] === "object" || "properties" in schema || "required" in schema
}

function matchesType(type: string, value: unknown): boolean {
  if (type === "array") return Array.isArray(value)
  if (type === "boolean") return typeof value === "boolean"
  if (type === "integer") return Number.isInteger(value)
  if (type === "null") return value === null
  if (type === "number") return typeof value === "number" && Number.isFinite(value)
  if (type === "object") return isRecord(value)
  if (type === "string") return typeof value === "string"
  return false
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value)
}
