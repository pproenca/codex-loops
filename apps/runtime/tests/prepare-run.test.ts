import assert from "node:assert/strict"
import { test } from "node:test"

import { InMemoryJournalStore } from "../src/consistency/journal-store.ts"
import { prepareWorkflowRun } from "../src/core/prepare-run.ts"
import { parseWorkflowCommandApiRequest, parseWorkflowCommandCliRequest, parseWorkflowProgrammaticCall } from "../src/trust/workflow-command.ts"
import { parseCliArgv } from "../src/trust/cli.ts"

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

const facts = {
  runId: "system-run-id",
  cwd: "/tmp",
  databasePath: "/tmp/runs_1.sqlite",
  scriptSha256: "abc",
} satisfies Parameters<typeof prepareWorkflowRun>[0]["facts"]

const script = {
  source: "export const meta = { name: \"wf\", description: \"test\" }\nreturn null\n",
  meta: { name: "wf", description: "test" },
  compatibility: { ok: true, findings: [] },
} satisfies Parameters<typeof prepareWorkflowRun>[0]["script"]

test("workflow command API parser uses requested run id as the durable run identity", () => {
  const request = parseWorkflowCommandApiRequest("workflow", {
    script: "wf.ts",
    args: { ticket: 123 },
    input: {
      provider: "mock",
      approved: true,
      runId: "requested-run-id",
    },
  })
  const prepared = prepareWorkflowRun({ request, provider: "mock", scriptPath: "/tmp/wf.ts", script, facts })

  assert.equal(prepared.runId, "requested-run-id")
  assert.deepEqual(prepared.requestedRunId, { t: "requested", value: "requested-run-id" })
  assert.equal(prepared.databasePath, "/tmp/runs_1.sqlite")
  assert.equal(Object.hasOwn(prepared, "journalPath"), false)
  assert.deepEqual(prepared.args, { ticket: 123 })
  assert.equal(prepared.provider, "mock")
})

test("workflow command CLI parser converts raw argv to semantic request", () => {
  const cli = parseCliArgv(["test", "wf.ts", "--args", "{\"ticket\":123}", "--run-id", "requested", "--mock"])
  const request = parseWorkflowCommandCliRequest(cli)

  assert.equal(request.command, "test")
  assert.deepEqual(request.script, { t: "unresolved", value: "wf.ts" })
  assert.deepEqual(request.args, { ticket: 123 })
  assert.deepEqual(request.provider, { t: "explicit", provider: "mock" })
  assert.deepEqual(request.requestedRunId, { t: "requested", value: "requested" })
})

test("workflow run commands reject removed journal flags", () => {
  assert.throws(
    () => parseWorkflowCommandCliRequest(parseCliArgv(["test", "wf.ts", "--journal", "run-1"])),
    /--journal was removed; use --run-id/,
  )
  assert.throws(
    () => parseWorkflowProgrammaticCall("workflow", "wf.ts", [{}, { journal: "run-1" }, {}]),
    /--journal was removed; use --run-id/,
  )
})

test("programmatic workflow parser preserves current public call surface", () => {
  const request = parseWorkflowProgrammaticCall("workflow", { scriptPath: "wf.ts" }, [
    { ticket: 123 },
    {
      provider: "mock",
      budget: "deep",
      codexConfig: { profile: "test" },
      turnBudget: 100,
      approved: true,
      runId: "api-run",
      maxAgents: 2,
    },
    { signal: undefined },
  ])

  assert.equal(request.command, "workflow")
  assert.deepEqual(request.script, { t: "unresolved", value: "wf.ts" })
  assert.deepEqual(request.args, { ticket: 123 })
  assert.deepEqual(request.provider, { t: "explicit", provider: "mock" })
  assert.deepEqual(request.requestedRunId, { t: "requested", value: "api-run" })
  assert.equal(request.options.budget, "deep")
  assert.deepEqual(request.options.codexConfig, { profile: "test" })
  assert.throws(() => parseWorkflowProgrammaticCall("workflow", "flow.ts", [{}, { codexConfig: null }, {}]))
  assert.throws(() => parseWorkflowProgrammaticCall("workflow", "flow.ts", [{}, { codexConfig: { unsupported: null } }, {}]))
  assert.equal(request.options.turnBudget, 100)
  assert.equal(request.options.limits.maxAgents, 2)
  assert.equal(request.options.limits.maxConcurrentAgents, 8)
})

test("workflow parser uses permissive structural defaults without a named budget", () => {
  const request = parseWorkflowProgrammaticCall("workflow", "wf.ts", [{}, {}, {}])

  assert.equal(request.options.limits.maxAgents, 1000)
  assert.equal(request.options.limits.maxConcurrentAgents, 8)
  assert.equal(request.options.limits.maxParallelItems, 4096)
  assert.equal(request.options.limits.maxPipelineItems, 4096)
  assert.equal(request.options.limits.taskBudgetTokens, undefined)
})

test("workflow parser maps small budget to conservative structural limits without a token ceiling", () => {
  const request = parseWorkflowProgrammaticCall("workflow", "wf.ts", [{}, { budget: "small" }, {}])

  assert.equal(request.options.limits.maxAgents, 6)
  assert.equal(request.options.limits.maxConcurrentAgents, 2)
  assert.equal(request.options.limits.taskBudgetTokens, undefined)
  assert.equal(request.options.limits.maxWorkItemsPerAgent, 6)
  assert.equal(request.options.limits.maxInventoryItemsReturned, 12)
  assert.equal(request.options.limits.maxMutationFilesPerRun, 12)
})

test("workflow parser maps standard and deep budgets without token ceilings", () => {
  const standard = parseWorkflowProgrammaticCall("workflow", "wf.ts", [{}, { budget: "standard" }, {}])
  const deep = parseWorkflowProgrammaticCall("workflow", "wf.ts", [{}, { budget: "deep" }, {}])

  assert.equal(standard.options.limits.taskBudgetTokens, undefined)
  assert.equal(deep.options.limits.taskBudgetTokens, undefined)
})

test("workflow parser lets explicit options override budget presets", () => {
  const request = parseWorkflowProgrammaticCall("workflow", "wf.ts", [{}, { budget: "small", maxAgents: 2, taskBudget: 100 }, {}])

  assert.equal(request.options.limits.maxAgents, 2)
  assert.equal(request.options.limits.maxConcurrentAgents, 2)
  assert.equal(request.options.limits.taskBudgetTokens, 100)
})

test("journal initialization commits the prepared run_opened record", async () => {
  const request = parseWorkflowCommandApiRequest("test", { script: "wf.ts", args: { ok: true }, input: {} })
  const prepared = prepareWorkflowRun({ request, provider: "mock", scriptPath: "/tmp/wf.ts", script, facts })
  const store = new InMemoryJournalStore()
  const committed = await store.initializeRun(prepared)

  assert.equal(committed.seq, 1)
  assert.equal(committed.event.t, "run_opened")
  assert.equal(committed.event.runId, "system-run-id")
  assert.deepEqual(committed.event.args, { ok: true })
})

test("core prepares policy records and SQLite storage from trusted request facts", () => {
  const request = parseWorkflowProgrammaticCall("workflow", "wf.ts", [
    {},
    { provider: "mock", maxAgents: 2, maxPromptBytesPerAgent: 24, runId: "stable-run" },
    {},
  ])
  const prepared = prepareWorkflowRun({ request, provider: "mock", scriptPath: "/tmp/wf.ts", script, facts })

  assert.equal(prepared.workflowName, "wf")
  assert.equal(prepared.runId, "stable-run")
  assert.equal(prepared.databasePath, "/tmp/runs_1.sqlite")
  assert.equal(Object.hasOwn(prepared, "journalPath"), false)
  assert.equal(prepared.limits.maxAgents, 2)
  assert.equal(prepared.limits.maxPromptBytesPerAgent, 24)
  assert.deepEqual(record(prepared.budgetPlan)["provider"], "mock")
  assert.deepEqual(record(prepared.runtimeContract)["remote"], { supported: false, reason: "this local runner resumes from durable local journals" })
})

function record(value: unknown): Record<string, unknown> {
  assert.equal(typeof value, "object")
  assert.notEqual(value, null)
  assert.equal(Array.isArray(value), false)
  return value as Record<string, unknown>
}
