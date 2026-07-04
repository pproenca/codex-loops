import assert from "node:assert/strict"
import { writeFile } from "node:fs/promises"
import { join } from "node:path"
import { test } from "node:test"

import { readJournalPath, runJournalQueryApp } from "../src/app/workflow-runner.ts"
import { foldJournal, toWorkflowSnapshot, toWorkflowStatusSummary } from "../src/core/journal-projection.ts"
import { buildServeStatusPayload, extractStaticAgentGoals } from "../src/core/serve-status.ts"
import type { JournalEvent } from "../src/domain/contracts.ts"
import { FileJournalReader } from "../src/effects/node/file-journal-reader.ts"
import { parseCliArgv } from "../src/trust/cli.ts"
import { parseJournalQueryCliRequest } from "../src/trust/journal-query.ts"
import { makeTempDir } from "./tmp.ts"

const limits = {
  maxAgents: 1,
  maxConcurrentAgents: 1,
  schemaRetryLimit: 1,
  maxWorkItemsPerAgent: 1,
  maxInventoryItemsReturned: 1,
  maxPromptBytesPerAgent: 1,
  maxMutationFilesPerAgent: 1,
  maxMutationFilesPerRun: 1,
  maxParallelItems: 1,
  maxPipelineItems: 1,
}

const budgetPlan = {
  provider: "mock",
  limits,
  expectedAgents: { minimum: 1, maximum: 1, basis: "test" },
  workload: { scopeKind: "bounded", batchable: false, runCompleteness: "full", basis: "test" },
  modelPolicySummary: { defaultEffort: "medium", minEffort: "medium", maxEffort: "xhigh", disallowedEfforts: [] },
  writeScope: { posture: "read-only", summary: "test" },
  tokenWarning: "test",
}

const runtimeContract = {
  activation: { allowed: true, source: "cli-command", command: "test", reason: "test" },
  permission: { decision: "allow", source: "test", autoDenied: false, ruleText: "test" },
  structuredOutput: { mode: "provider-schema", failClosed: true, schemaRetryLimit: 1 },
  scheduling: {
    maxAgents: 1,
    maxConcurrentAgents: 1,
    queueExcessAgents: true,
    queueStateVisible: true,
    releaseSlotsOnTerminalState: true,
  },
  budgeting: { accountingFields: ["tokens"], thresholdPolicy: "test" },
  resume: { cacheKey: "runId+phaseTitle+label+promptHash+schemaHash+optionsHash", completedNodesReplayFromJournal: true },
  remote: { supported: false, reason: "test" },
}

const nodeId = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
const events = [
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
  { seq: 2, t: "phase_entered", phase: 0, title: "Phase" },
  {
    seq: 3,
    t: "agent_scheduled",
    node: nodeId,
    label: "Agent",
    phase: 0,
    phaseTitle: "Phase",
    attempt: 1,
    promptHash: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    optionsHash: "dddddddddddddddddddddddddddddddd",
    promptPreview: "prompt",
    effort: "medium",
  },
  { seq: 4, t: "agent_started", node: nodeId, attempt: 1, threadId: "thread-1" },
  { seq: 5, t: "agent_completed", node: nodeId, attempt: 1, result: { ok: true }, tokens: 3, toolCalls: 1, durationMs: 20, source: "mock" },
  { seq: 6, t: "run_finished", status: "done", result: { ok: true }, totalTokens: 3, totalToolCalls: 1, durationMs: 50 },
] satisfies readonly JournalEvent[]

test("core folds journal events into snapshot and status projections", () => {
  const state = foldJournal({ events, truncatedTail: false })
  const snapshot = toWorkflowSnapshot({ state, journalPath: "/tmp/run.jsonl" })
  const summary = toWorkflowStatusSummary({ state, tailEvents: events, eventLimit: 2 })

  assert.equal(snapshot.schemaVersion, "workflow-snapshot/v2")
  assert.equal(snapshot.status, "done")
  assert.equal(snapshot.phases[0]?.nodes[0]?.state, "done")
  assert.equal(snapshot.totalTokens, 3)
  assert.equal(summary.lastEvents.length, 2)
  assert.equal(summary.nodeCounts.done, 1)
})

test("serve status payload contains status JSON and enriched static goals", () => {
  const opened = events[0] as Extract<JournalEvent, { readonly t: "run_opened" }>
  const payload = buildServeStatusPayload({
    read: { opened, events, truncatedTail: false },
    journalPath: "/tmp/run.jsonl",
    eventLimit: 2,
    agentGoals: { Agent: "full prompt with all details and no preview truncation" },
  })
  const statusPayload = JSON.parse(payload.prettyPayload)
  assert.equal(statusPayload.status.phases[0].nodes[0].promptFull, "full prompt with all details and no preview truncation")
  assert.deepEqual(Object.keys(payload).sort(), ["compactPayload", "prettyPayload"])
})

test("status goal enrichment extracts static labeled workflow agent prompts", () => {
  const goals = extractStaticAgentGoals(`export const meta = { name: "wf", description: "test" }
phase("Source inventory")
await agent(\`Inventory everything.
Do not truncate this goal.\`, { label: "documentation-inventory", isolation: "read-only" })
`)

  assert.equal(goals["documentation-inventory"], "Inventory everything.\nDo not truncate this goal.")
})

test("file journal reader parses lines through trust and detects torn tail", async () => {
  const dir = await makeTempDir("agent-loops-")
  const journalPath = join(dir, "run.jsonl")
  await writeFile(journalPath, `${events.map((event) => JSON.stringify(event)).join("\n")}\n{"seq"`, "utf8")

  const { read } = await readJournalPath(journalPath, { journalReader: new FileJournalReader() })
  assert.equal(read.events.length, events.length)
  assert.equal(read.truncatedTail, true)
})

test("app inspect/status path uses parsed journal query and journal reader port", async () => {
  const dir = await makeTempDir("agent-loops-")
  const journalPath = join(dir, "run.jsonl")
  await writeFile(journalPath, `${events.map((event) => JSON.stringify(event)).join("\n")}\n`, "utf8")
  const env = { journalReader: new FileJournalReader() }

  const inspectRequest = parseJournalQueryCliRequest(parseCliArgv(["inspect", "--journal", journalPath, "--json"]))
  const inspectResult = await runJournalQueryApp(inspectRequest, env)
  assert.equal(inspectResult.status, "inspected")

  const statusRequest = parseJournalQueryCliRequest(parseCliArgv(["status", "--journal", journalPath, "--event-limit", "1", "--json"]))
  const statusResult = await runJournalQueryApp(statusRequest, env)
  assert.equal(statusResult.status, "summarized")
  if (statusResult.status === "summarized") assert.equal(statusResult.summary.lastEvents.length, 1)
})
