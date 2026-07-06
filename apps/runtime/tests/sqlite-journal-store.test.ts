import assert from "node:assert/strict"
import { DatabaseSync } from "node:sqlite"
import { rm } from "node:fs/promises"
import { join } from "node:path"
import { test } from "node:test"

import { readRun } from "../src/app/workflow-runner.ts"
import { SqliteJournalStore } from "../src/consistency/sqlite-journal-store.ts"
import { JournalCommitConflict } from "../src/consistency/journal-store.ts"
import type { JournalEventDraft } from "../src/domain/contracts.ts"
import { SqliteJournalDirectory, SqliteJournalReader } from "../src/effects/node/sqlite-journal-reader.ts"
import { defaultWorkflowDatabasePath } from "../src/effects/node/workflow-database.ts"
import type { ProcessPort } from "../src/ports/index.ts"
import { parseJournalMutationText } from "../src/trust/journal-mutations.ts"
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

test("default workflow database path uses schema-versioned sqlite storage under the Codex home", () => {
  assert.equal(defaultWorkflowDatabasePath("/tmp/home"), "/tmp/home/.codex/workflows/runs_1.sqlite")
})

test("sqlite journal store creates schema, writes events, and resolves latest by run id", async () => {
  const root = await makeTempDir("agent-loops-sqlite-")
  try {
    const databasePath = join(root, "runs_1.sqlite")
    const store = new SqliteJournalStore(databasePath, "run-1", processPort({ pid: 100 }))
    await store.initializeRun(preparedRun(databasePath, "run-1"))
    const logged = await store.commit({ idempotencyKey: "log", event: { t: "log_emitted", message: "hello" } })
    await store.recordMutationFiles({ idempotencyKey: "mutation", mutation: { node: "node-1", attempt: 1, files: ["a.ts"] } })
    await store.release()

    assert.equal(logged.seq, 2)
    assert.equal(logged.event.seq, 2)
    assert.equal("ts" in logged.event, false)

    const db = new DatabaseSync(databasePath, { readOnly: true })
    try {
      const tables = db.prepare("select name from sqlite_master where type = 'table' order by name").all().map((row) => row["name"])
      assert.deepEqual(tables, ["events", "idempotency_keys", "metadata", "mutations", "run_locks", "runs", "serve_sessions"])
      assert.equal(db.prepare("select value from metadata where key = 'storage_schema_version'").get()?.["value"], "1")
      const runColumns = db.prepare("pragma table_info(runs)").all().map((row) => row["name"])
      assert.equal(runColumns.includes("journal_path"), false)
    } finally {
      db.close()
    }

    const reader = new SqliteJournalReader(databasePath)
    const resolved = await readRun("latest", { journalReader: reader })
    assert.equal(resolved.databasePath, databasePath)
    assert.equal(resolved.runId, "run-1")
    assert.equal(Object.hasOwn(resolved, "journalPath"), false)
    assert.equal(resolved.read.truncatedTail, false)
    assert.deepEqual(resolved.read.events.map((event) => event.t), ["run_opened", "log_emitted"])
    assert.deepEqual(parseJournalMutationText(await reader.readMutationText(resolved.runId)), ["a.ts"])
  } finally {
    await rm(root, { recursive: true, force: true })
  }
})

test("sqlite journal directory lists runs by recent update time", async () => {
  const root = await makeTempDir("agent-loops-sqlite-list-")
  try {
    const databasePath = join(root, "runs_1.sqlite")
    const first = new SqliteJournalStore(databasePath, "run-1", processPort({ pid: 101 }))
    await first.initializeRun(preparedRun(databasePath, "run-1"))
    await first.release()
    const second = new SqliteJournalStore(databasePath, "run-2", processPort({ pid: 102 }))
    await second.initializeRun(preparedRun(databasePath, "run-2"))
    await second.commit({ idempotencyKey: "log", event: { t: "log_emitted", message: "newer" } })
    await second.release()

    const candidates = await new SqliteJournalDirectory(databasePath).listRuns()
    assert.deepEqual(candidates.map((candidate) => candidate.runId), ["run-2", "run-1"])
    assert.equal(candidates.every((candidate) => candidate.databasePath === databasePath), true)
  } finally {
    await rm(root, { recursive: true, force: true })
  }
})

test("sqlite journal store rejects live lock owners and releases locks", async () => {
  const root = await makeTempDir("agent-loops-sqlite-lock-")
  try {
    const databasePath = join(root, "runs_1.sqlite")
    const first = new SqliteJournalStore(databasePath, "run-1", processPort({ pid: 200 }))
    await first.initializeRun(preparedRun(databasePath, "run-1"))

    const blocked = new SqliteJournalStore(databasePath, "run-1", processPort({ pid: 201, alivePids: [200] }))
    await assert.rejects(
      () => blocked.commit({ idempotencyKey: "blocked", event: { t: "log_emitted", message: "blocked" } }),
      JournalCommitConflict,
    )

    await first.release()
    const resumed = new SqliteJournalStore(databasePath, "run-1", processPort({ pid: 202 }))
    const logged = await resumed.commit({ idempotencyKey: "after-release", event: { t: "log_emitted", message: "after" } })
    assert.equal(logged.seq, 2)
    await resumed.release()
  } finally {
    await rm(root, { recursive: true, force: true })
  }
})

function preparedRun(databasePath: string, runId: string) {
  return {
    command: "test",
    runId,
    workflowName: runOpened.workflowName,
    scriptPath: runOpened.scriptPath,
    scriptSha256: runOpened.scriptSha256,
    databasePath,
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
