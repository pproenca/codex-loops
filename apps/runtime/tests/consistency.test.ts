import assert from "node:assert/strict"
import { readFile, rm, utimes, writeFile } from "node:fs/promises"
import { basename, join } from "node:path"
import { test } from "node:test"

import { readJournalPath } from "../src/app/workflow-runner.ts"
import { FileJournalStore } from "../src/consistency/file-journal-store.ts"
import { InMemoryJournalStore, JournalCommitConflict } from "../src/consistency/journal-store.ts"
import type { JournalEventDraft } from "../src/domain/contracts.ts"
import { FileJournalReader } from "../src/effects/node/file-journal-reader.ts"
import type { ProcessPort } from "../src/ports/index.ts"
import { makeTempDir } from "./tmp.ts"

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

test("file journal store strips runtime sequence fields from widened drafts", async () => {
  const root = await makeTempDir("agent-loops-seq-strip-")
  try {
    const journalPath = join(root, "seq-strip.jsonl")
    const store = new FileJournalStore(journalPath, processPort({ pid: 110 }))
    await store.initializeRun(preparedRun(journalPath))
    const polluted = {
      t: "log_emitted",
      message: "hello",
      seq: 999,
      ts: "forged",
      injected: true,
    } as unknown as JournalEventDraft
    const committed = await store.commit({ idempotencyKey: "log", event: polluted })
    await store.release()

    assert.equal(committed.seq, 2)
    assert.equal(committed.event.seq, 2)
    assert.equal("ts" in committed.event, false)
    assert.equal("injected" in committed.event, false)
    const text = await readFile(journalPath, "utf8")
    assert.doesNotMatch(text, /999|forged|injected/)
  } finally {
    await rm(root, { recursive: true, force: true })
  }
})

test("file journal store serializes concurrent commits in persisted sequence order", async () => {
  const root = await makeTempDir("agent-loops-concurrent-")
  try {
    const journalPath = join(root, "concurrent.jsonl")
    const store = new FileJournalStore(journalPath, processPort({ pid: 113 }))
    await store.initializeRun(preparedRun(journalPath))

    await Promise.all(Array.from({ length: 40 }, (_, index) => {
      const event: JournalEventDraft = index % 2 === 0
        ? { t: "runner_heartbeat", pid: 113 }
        : { t: "log_emitted", message: `log ${index}` }
      return store.commit({ idempotencyKey: `concurrent:${index}`, event })
    }))
    await store.release()

    const { read } = await readJournalPath(journalPath, { journalReader: new FileJournalReader() })
    assert.equal(read.truncatedTail, false)
    assert.deepEqual(read.events.map((event) => event.seq), Array.from({ length: 41 }, (_, index) => index + 1))
  } finally {
    await rm(root, { recursive: true, force: true })
  }
})

test("journal initialization is idempotent for the same prepared run", async () => {
  const store = new InMemoryJournalStore()
  const prepared = {
    command: "test",
    runId: runOpened.runId,
    workflowName: runOpened.workflowName,
    scriptPath: runOpened.scriptPath,
    scriptSha256: runOpened.scriptSha256,
    journalPath: "/tmp/run.jsonl",
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

test("file journal store persists run_opened before publishing latest pointer", async () => {
  const root = await makeTempDir("agent-loops-")
  try {
    const journalPath = join(root, "demo-12345678.jsonl")
    const pointerPath = join(root, "latest.json")
    const store = new FileJournalStore(journalPath, processPort({ pid: 100 }))
    const prepared = {
      command: "test",
      runId: runOpened.runId,
      workflowName: runOpened.workflowName,
      scriptPath: runOpened.scriptPath,
      scriptSha256: runOpened.scriptSha256,
      journalPath,
      args: runOpened.args,
      provider: runOpened.provider,
      budgetPlan: runOpened.budgetPlan,
      limits: runOpened.limits,
      runtimeContract: runOpened.runtimeContract,
      requestedRunId: { t: "none" },
      pointerPath,
      pointerTarget: basename(journalPath),
    } as const

    await store.initializeRun(prepared)
    await store.commit({ idempotencyKey: "finish", event: runFinished("done") })

    assert.deepEqual(JSON.parse(await readFile(pointerPath, "utf8")), { $pointer: basename(journalPath) })
    const { read } = await readJournalPath(pointerPath, { journalReader: new FileJournalReader() })
    assert.equal(read.truncatedTail, false)
    assert.deepEqual(read.events.map((event) => event.t), ["run_opened", "run_finished"])
    assert.equal(read.events[0]?.seq, 1)
    assert.equal(read.events[1]?.seq, 2)
    await store.release()
  } finally {
    await rm(root, { recursive: true, force: true })
  }
})

test("file journal store treats malformed locks as contention", async () => {
  const root = await makeTempDir("agent-loops-lock-")
  try {
    const journalPath = join(root, "locked.jsonl")
    await writeFile(`${journalPath}.lock`, "\n", "utf8")
    const store = new FileJournalStore(journalPath, processPort({ pid: 101 }))

    await assert.rejects(() => store.initializeRun(preparedRun(journalPath)), JournalCommitConflict)
  } finally {
    await rm(root, { recursive: true, force: true })
  }
})

test("file journal store rejects live lock owners and takes over dead owners", async () => {
  const root = await makeTempDir("agent-loops-lock-")
  try {
    const journalPath = join(root, "takeover.jsonl")
    await writeFile(`${journalPath}.lock`, "200\n", "utf8")
    const liveStore = new FileJournalStore(journalPath, processPort({ pid: 102, alivePids: [200] }))
    await assert.rejects(() => liveStore.initializeRun(preparedRun(journalPath)), JournalCommitConflict)

    const takeoverStore = new FileJournalStore(journalPath, processPort({ pid: 103 }))
    const opened = await takeoverStore.initializeRun(preparedRun(journalPath))
    assert.equal(opened.seq, 1)
    await takeoverStore.release()
    await assert.rejects(() => readFile(`${journalPath}.lock`, "utf8"))
  } finally {
    await rm(root, { recursive: true, force: true })
  }
})

test("file journal store uses fresh journal heartbeat before rejecting live lock owners", async () => {
  const root = await makeTempDir("agent-loops-lock-heartbeat-")
  try {
    const journalPath = join(root, "heartbeat.jsonl")
    await writeFile(`${journalPath}.lock`, "200\n", "utf8")
    await writeFile(journalPath, [
      JSON.stringify({ seq: 1, ...runOpened }),
      JSON.stringify({ seq: 2, t: "runner_attached", pid: 200, mode: "fresh", cliVersion: "0.2.0" }),
      JSON.stringify({ seq: 3, t: "runner_heartbeat", pid: 200, ts: new Date().toISOString() }),
      "",
    ].join("\n"), "utf8")
    const old = new Date(Date.now() - 60_000)
    await utimes(`${journalPath}.lock`, old, old)

    const liveStore = new FileJournalStore(journalPath, processPort({ pid: 201, alivePids: [200] }))
    await assert.rejects(() => liveStore.commit({ idempotencyKey: "finish", event: runFinished("done") }), JournalCommitConflict)
  } finally {
    await rm(root, { recursive: true, force: true })
  }
})

test("file journal store takes over alive pids with stale journal heartbeat", async () => {
  const root = await makeTempDir("agent-loops-lock-heartbeat-stale-")
  try {
    const journalPath = join(root, "heartbeat-stale.jsonl")
    await writeFile(`${journalPath}.lock`, "200\n", "utf8")
    await writeFile(journalPath, [
      JSON.stringify({ seq: 1, ...runOpened }),
      JSON.stringify({ seq: 2, t: "runner_attached", pid: 200, mode: "fresh", cliVersion: "0.2.0" }),
      JSON.stringify({ seq: 3, t: "runner_heartbeat", pid: 200, ts: "2000-01-01T00:00:00.000Z" }),
      "",
    ].join("\n"), "utf8")
    const old = new Date(Date.now() - 60_000)
    await utimes(`${journalPath}.lock`, old, old)

    const takeoverStore = new FileJournalStore(journalPath, processPort({ pid: 202, alivePids: [200] }))
    const finished = await takeoverStore.commit({ idempotencyKey: "finish", event: runFinished("done") })
    assert.equal(finished.seq, 4)
    await takeoverStore.release()
  } finally {
    await rm(root, { recursive: true, force: true })
  }
})

test("file journal store recovers sequence from existing committed events", async () => {
  const root = await makeTempDir("agent-loops-recover-")
  try {
    const journalPath = join(root, "recover.jsonl")
    const first = new FileJournalStore(journalPath, processPort({ pid: 104 }))
    await first.initializeRun(preparedRun(journalPath))
    await first.release()

    const second = new FileJournalStore(journalPath, processPort({ pid: 105 }))
    const finished = await second.commit({ idempotencyKey: "finish", event: runFinished("done") })
    assert.equal(finished.seq, 2)
    await second.release()
  } finally {
    await rm(root, { recursive: true, force: true })
  }
})

test("file journal store recovers run_opened idempotency without rewriting", async () => {
  const root = await makeTempDir("agent-loops-recover-open-")
  try {
    const journalPath = join(root, "recover-open.jsonl")
    const first = new FileJournalStore(journalPath, processPort({ pid: 106 }))
    const opened = await first.initializeRun(preparedRun(journalPath))
    await first.release()

    const second = new FileJournalStore(journalPath, processPort({ pid: 107 }))
    const recovered = await second.initializeRun(preparedRun(journalPath))
    await second.release()

    assert.equal(recovered.seq, opened.seq)
    const { read } = await readJournalPath(journalPath, { journalReader: new FileJournalReader() })
    assert.equal(read.events.filter((event) => event.t === "run_opened").length, 1)
  } finally {
    await rm(root, { recursive: true, force: true })
  }
})

test("file journal store recovers mid-run idempotency without rewriting", async () => {
  const root = await makeTempDir("agent-loops-recover-mid-")
  try {
    const journalPath = join(root, "recover-mid.jsonl")
    const first = new FileJournalStore(journalPath, processPort({ pid: 111 }))
    await first.initializeRun(preparedRun(journalPath))
    await first.commit({
      idempotencyKey: "runner_attached:run-1:111",
      event: { t: "runner_attached", pid: 111, mode: "fresh", cliVersion: "0.2.0" },
    })
    const logged = await first.commit({ idempotencyKey: "workflow_event:run-1:1:log_emitted", event: { t: "log_emitted", message: "hello" } })
    await first.release()

    const second = new FileJournalStore(journalPath, processPort({ pid: 112 }))
    const recovered = await second.commit({ idempotencyKey: "workflow_event:run-1:1:log_emitted", event: { t: "log_emitted", message: "hello" } })
    await second.release()

    assert.equal(recovered.seq, logged.seq)
    const { read } = await readJournalPath(journalPath, { journalReader: new FileJournalReader() })
    assert.equal(read.events.filter((event) => event.t === "log_emitted").length, 1)
  } finally {
    await rm(root, { recursive: true, force: true })
  }
})

test("file journal store recovers terminal idempotency without rewriting", async () => {
  const root = await makeTempDir("agent-loops-recover-finish-")
  try {
    const journalPath = join(root, "recover-finish.jsonl")
    const first = new FileJournalStore(journalPath, processPort({ pid: 108 }))
    await first.initializeRun(preparedRun(journalPath))
    const finished = await first.commit({ idempotencyKey: "run_finished:run-1", event: runFinished("done") })
    await first.release()

    const second = new FileJournalStore(journalPath, processPort({ pid: 109 }))
    const recovered = await second.commit({ idempotencyKey: "run_finished:run-1", event: runFinished("done") })
    await second.release()

    assert.equal(recovered.seq, finished.seq)
    const { read } = await readJournalPath(journalPath, { journalReader: new FileJournalReader() })
    assert.equal(read.events.filter((event) => event.t === "run_finished").length, 1)
  } finally {
    await rm(root, { recursive: true, force: true })
  }
})

function preparedRun(journalPath: string) {
  return {
    command: "test",
    runId: runOpened.runId,
    workflowName: runOpened.workflowName,
    scriptPath: runOpened.scriptPath,
    scriptSha256: runOpened.scriptSha256,
    journalPath,
    args: runOpened.args,
    provider: runOpened.provider,
    budgetPlan: runOpened.budgetPlan,
    limits: runOpened.limits,
    runtimeContract: runOpened.runtimeContract,
    requestedRunId: { t: "none" },
  } as const
}

function processPort(input: { readonly pid: number; readonly alivePids?: readonly number[] | undefined }): ProcessPort {
  return {
    pid() {
      return input.pid
    },
    cwd() {
      return "/tmp"
    },
    probePid(pid: number) {
      if (input.alivePids?.includes(pid) === true) return
      throw Object.assign(new Error("missing pid"), { code: "ESRCH" })
    },
  }
}
