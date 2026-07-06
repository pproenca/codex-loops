import assert from "node:assert/strict"
import { test } from "node:test"

import { InMemoryJournalStore, JournalCommitConflict } from "../src/consistency/journal-store.ts"
import type { JournalEventDraft } from "../src/domain/contracts.ts"

type RunOpenedDraft = Extract<JournalEventDraft, { readonly t: "run_opened" }>

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
} as const

const budgetPlan = {
  provider: "mock",
  limits,
  expectedAgents: { minimum: 0, maximum: 0, basis: "test" },
  workload: { scopeKind: "bounded", batchable: false, runCompleteness: "full", basis: "test" },
  modelPolicySummary: { defaultEffort: "medium", minEffort: "medium", maxEffort: "xhigh", disallowedEfforts: [] },
  writeScope: { posture: "read-only", summary: "test" },
  tokenWarning: "test",
} as const

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
} as const

const runOpened: RunOpenedDraft = {
  t: "run_opened",
  schema: "agent-loops/journal@2",
  runId: "run-1",
  workflowName: "wf",
  scriptPath: "/tmp/wf.ts",
  scriptSha256: "abc",
  args: {},
  provider: "mock",
  budgetPlan,
  limits,
  runtimeContract,
}

const runFinished = (status: "done" | "failed" | "killed"): JournalEventDraft => ({
  t: "run_finished",
  status,
  totalTokens: 0,
  totalToolCalls: 0,
  durationMs: 0,
})

test("journal store is the sequence authority", async () => {
  const store = new InMemoryJournalStore()
  const opened = await store.commit({ idempotencyKey: "open", event: runOpened })
  const finished = await store.commit({ idempotencyKey: "finish", event: runFinished("done") })

  assert.equal(opened.seq, 1)
  assert.equal(finished.seq, 2)
  assert.deepEqual(store.snapshot(), [opened, finished])
})

test("journal store permits only one terminal run event", async () => {
  const store = new InMemoryJournalStore()
  await store.commit({ idempotencyKey: "open", event: runOpened })
  await store.commit({ idempotencyKey: "finish-1", event: runFinished("failed") })

  await assert.rejects(
    () => store.commit({ idempotencyKey: "finish-2", event: runFinished("killed") }),
    JournalCommitConflict,
  )
})

test("journal store makes duplicate idempotency keys stable", async () => {
  const store = new InMemoryJournalStore()
  const opened = await store.commit({ idempotencyKey: "open", event: runOpened })
  const first = await store.commit({ idempotencyKey: "finish", event: runFinished("done") })
  const second = await store.commit({ idempotencyKey: "finish", event: runFinished("done") })

  assert.equal(second, first)
  assert.deepEqual(store.snapshot(), [opened, first])
})

test("journal store rejects idempotency key reuse for different events", async () => {
  const store = new InMemoryJournalStore()
  await store.commit({ idempotencyKey: "open", event: runOpened })
  await store.commit({ idempotencyKey: "finish", event: runFinished("done") })

  await assert.rejects(
    () => store.commit({ idempotencyKey: "finish", event: runFinished("failed") }),
    JournalCommitConflict,
  )
})

test("journal store requires run_opened first and once", async () => {
  const store = new InMemoryJournalStore()
  await assert.rejects(
    () => store.commit({ idempotencyKey: "finish", event: runFinished("done") }),
    JournalCommitConflict,
  )
  await store.commit({ idempotencyKey: "open", event: runOpened })
  await assert.rejects(
    () => store.commit({ idempotencyKey: "open-2", event: { ...runOpened, runId: "run-2" } }),
    JournalCommitConflict,
  )
})

test("in-memory journal store strips runtime sequence fields from widened drafts", async () => {
  const store = new InMemoryJournalStore()
  await store.commit({ idempotencyKey: "open", event: runOpened })
  const polluted = {
    t: "log_emitted",
    message: "hello",
    seq: 999,
    ts: "forged",
    injected: true,
  } as unknown as JournalEventDraft
  const committed = await store.commit({ idempotencyKey: "log", event: polluted })

  assert.equal(committed.seq, 2)
  assert.equal(committed.event.seq, 2)
  assert.equal("ts" in committed.event, false)
  assert.equal("injected" in committed.event, false)
})

test("journal initialization is idempotent for the same prepared run", async () => {
  const store = new InMemoryJournalStore()
  const prepared = {
    command: "test",
    runId: runOpened.runId,
    workflowName: runOpened.workflowName,
    scriptPath: runOpened.scriptPath,
    scriptSha256: runOpened.scriptSha256,
    databasePath: "/tmp/runs_1.sqlite",
    args: runOpened.args,
    provider: runOpened.provider,
    budgetPlan: runOpened.budgetPlan,
    limits: runOpened.limits,
    runtimeContract: runOpened.runtimeContract,
    requestedRunId: { t: "none" },
  } as const

  const first = await store.initializeRun(prepared)
  const second = await store.initializeRun(prepared)
  assert.equal(second, first)
  assert.deepEqual(store.snapshot(), [first])
})
