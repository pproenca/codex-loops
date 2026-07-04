import assert from "node:assert/strict"
import { mkdir, readFile, readdir, rm, symlink, writeFile } from "node:fs/promises"
import { join } from "node:path"
import { spawnSync } from "node:child_process"
import { test } from "node:test"
import { fileURLToPath } from "node:url"

import { IsolatedWorkflowExecutor } from "../src/app/isolated-workflow-executor.ts"
import { runResumeCommandApp, runServeCommandApp, runWorkflowCommandApp } from "../src/app/workflow-runner.ts"
import { FileDraftWorkflowStore } from "../src/consistency/draft-workflow-store.ts"
import { FileJournalStoreFactory } from "../src/consistency/file-journal-store.ts"
import { FileServePortfileStore } from "../src/consistency/serve-portfile-store.ts"
import { InMemoryJournalStoreFactory } from "../src/consistency/journal-store.ts"
import { FileJournalDirectory } from "../src/effects/node/file-journal-directory.ts"
import { FileJournalReader } from "../src/effects/node/file-journal-reader.ts"
import { NodeStatusServerPort } from "../src/effects/node/status-server.ts"
import { NodeWorkflowScriptSourceStore } from "../src/effects/node/workflow-script-source-store.ts"
import { NodeWorkflowChildResolver, NodeWorkflowPreparer, NodeWorkflowScriptLocator } from "../src/effects/node/workflow-preparer.ts"
import type { BackgroundProcessLauncher, ProviderAgentTurnPort, RunnerHeartbeatPort, StatusServerPort } from "../src/ports/index.ts"
import { parseCliArgv, parseWorkflowCliEnvelope } from "../src/trust/cli.ts"
import { parseWorkflowChildExecutionPolicy } from "../src/trust/containment.ts"
import { parseJournalEventLine } from "../src/trust/journal-event.ts"
import { parseResumeCliRequest } from "../src/trust/resume-command.ts"
import { parseServerAddress } from "../src/trust/server-address.ts"
import { parseServeCliRequest } from "../src/trust/serve-command.ts"
import { parseStatusServerRoute } from "../src/trust/status-server-route.ts"
import { parseWorkflowProgrammaticCall } from "../src/trust/workflow-command.ts"
import { makeTempDir } from "./tmp.ts"

function appEnv() {
  return {
    journalReader: new FileJournalReader(),
    journalDirectory: new FileJournalDirectory(),
    journalStoreFactory: new InMemoryJournalStoreFactory(),
    servePortfileStore: new FileServePortfileStore(),
    draftWorkflowStore: new FileDraftWorkflowStore(),
    processPort: processPort(),
    workflowScriptLocator: new NodeWorkflowScriptLocator(),
    workflowPreparer: new NodeWorkflowPreparer(),
    workflowScriptSourceStore: new NodeWorkflowScriptSourceStore(),
    workflowExecutor: new IsolatedWorkflowExecutor({
      policy: parseWorkflowChildExecutionPolicy({}),
      callerSignal: new AbortController().signal,
    }),
    backgroundLauncher: new FakeBackgroundProcessLauncher(),
    runnerHeartbeat: new FakeRunnerHeartbeat(),
  }
}

test("test workflow app path completes through preparer, JournalStore, and mock executor", async () => {
  const fixture = await workflowFixture()
  try {
    const result = await runWorkflowCommandApp(
      parseWorkflowProgrammaticCall("test", fixture.scriptPath, [{ ticket: 123 }, {}, {}]),
      appEnv(),
    )

    assert.equal(result.status, "completed")
    if (result.status !== "completed") return
    assert.equal(result.command, "test")
    assert.equal(result.snapshot.status, "done")
    assert.equal(result.snapshot.runner?.pid, 12345)
    assert.equal(result.snapshot.workflowName, "demo")
    assert.deepEqual(result.snapshot.result, {
      label: "agent",
      summary: "Mock workflow result.",
      prompt: "do the work",
    })
    assert.equal(result.snapshot.agentCount, 1)
    assert.equal(record(result.budgetPlan)["provider"], "mock")
  } finally {
    await fixture.dispose()
  }
})

test("workflow app path fails closed when live SDK provider is not configured", async () => {
  const fixture = await workflowFixture()
  try {
    const result = await runWorkflowCommandApp(
      parseWorkflowProgrammaticCall("workflow", fixture.scriptPath, [{ ticket: 123 }, {}, {}]),
      appEnv(),
    )

    assert.equal(result.status, "completed")
    if (result.status !== "completed") return
    assert.equal(result.snapshot.status, "failed")
    assert.notEqual(result.snapshot.error, undefined)
    if (result.snapshot.error === undefined) return
    assert.match(result.snapshot.error, /live SDK provider is not configured/)
  } finally {
    await fixture.dispose()
  }
})

test("workflow app path runs live provider through raw SDK event trust parsing", async () => {
  const fixture = await workflowFixture()
  const provider = new FakeProviderAgentTurn()
  try {
    const result = await runWorkflowCommandApp(
      parseWorkflowProgrammaticCall("workflow", fixture.scriptPath, [{ ticket: 123 }, {
        codexBaseUrl: "https://codex.example.test",
        codexPathOverride: "/bin/codex-test",
        codexConfig: { profile: "refactor" },
        skipGitRepoCheck: true,
      }, {}]),
      {
        ...appEnv(),
        workflowExecutor: new IsolatedWorkflowExecutor({
          policy: parseWorkflowChildExecutionPolicy({}),
          providerAgentTurn: provider,
          callerSignal: new AbortController().signal,
        }),
      },
    )

    assert.equal(result.status, "completed")
    if (result.status !== "completed") return
    assert.equal(result.snapshot.status, "done")
    assert.deepEqual(result.snapshot.result, "live result")
    assert.equal(result.snapshot.totalTokens, 7)
    assert.equal(result.snapshot.phases[0]?.nodes[0]?.threadId, "thread-live")
    assert.equal(provider.requests.length, 1)
    assert.equal(provider.requests[0]?.codexBaseUrl, "https://codex.example.test")
    assert.equal(provider.requests[0]?.codexPathOverride, "/bin/codex-test")
    assert.deepEqual(provider.requests[0]?.codexConfig, { profile: "refactor" })
    assert.equal(provider.requests[0]?.skipGitRepoCheck, true)
    const requestPrompt = provider.requests[0]?.prompt
    if (requestPrompt === undefined) assert.fail("provider request prompt was missing")
    assert.ok(requestPrompt.startsWith("You are a subagent spawned by an Codex Loops workflow orchestration script."))
    assert.match(requestPrompt, /Workflow node label: agent/)
    assert.ok(requestPrompt.endsWith("do the work"))
  } finally {
    await fixture.dispose()
  }
})

test("structured provider output retries malformed JSON and journals the retry", async () => {
  const fixture = await workflowFixture(`export const meta = { name: "demo", description: "Valid test workflow" }
const result = await agent("return json", { label: "agent", schema: { type: "object" } })
return result
`)
  const journalPath = join(fixture.root, "schema-retry.jsonl")
  const provider = new FakeProviderAgentTurn(["not json", "{\"ok\":true}"])
  try {
    const result = await runWorkflowCommandApp(
      parseWorkflowProgrammaticCall("workflow", fixture.scriptPath, [{ ticket: 123 }, { journal: journalPath, schemaRetryLimit: 1 }, {}]),
      {
        ...appEnv(),
        journalStoreFactory: new FileJournalStoreFactory(processPort()),
        workflowExecutor: new IsolatedWorkflowExecutor({
          policy: parseWorkflowChildExecutionPolicy({}),
          providerAgentTurn: provider,
          callerSignal: new AbortController().signal,
        }),
      },
    )

    assert.equal(result.status, "completed")
    if (result.status !== "completed") return
    assert.equal(result.snapshot.status, "done")
    assert.deepEqual(result.snapshot.result, { ok: true })
    assert.equal(result.snapshot.phases[0]?.nodes[0]?.attempt, 2)
    assert.equal(provider.requests.length, 2)
    const journalEvents = (await readFile(journalPath, "utf8")).trim().split("\n").map((line) => parseJournalEventLine(line))
    assert.equal(journalEvents.filter((event) => event.t === "agent_retried").length, 1)
    assert.equal(journalEvents.filter((event) => event.t === "agent_completed").length, 1)
  } finally {
    await fixture.dispose()
  }
})

test("structured provider output refuses retry after possible external writes", async () => {
  const fixture = await workflowFixture(`export const meta = { name: "demo", description: "Valid test workflow" }
const result = await agent("return json", { label: "agent", isolation: "workspace-write", schema: { type: "object" } })
return result
`)
  const journalPath = join(fixture.root, "schema-write-failclosed.jsonl")
  const provider = new FakeProviderAgentTurn(["not json", "{\"ok\":true}"])
  try {
    const result = await runWorkflowCommandApp(
      parseWorkflowProgrammaticCall("workflow", fixture.scriptPath, [{ ticket: 123 }, { journal: journalPath, schemaRetryLimit: 1 }, {}]),
      {
        ...appEnv(),
        journalStoreFactory: new FileJournalStoreFactory(processPort()),
        workflowExecutor: new IsolatedWorkflowExecutor({
          policy: parseWorkflowChildExecutionPolicy({}),
          providerAgentTurn: provider,
          callerSignal: new AbortController().signal,
        }),
      },
    )

    assert.equal(result.status, "completed")
    if (result.status !== "completed") return
    assert.equal(result.snapshot.status, "failed")
    assert.match(result.snapshot.error ?? "", /structured output retry refused for workspace-write isolation/)
    assert.equal(provider.requests.length, 1)
    const journalEvents = (await readFile(journalPath, "utf8")).trim().split("\n").map((line) => parseJournalEventLine(line))
    assert.equal(journalEvents.filter((event) => event.t === "agent_retried").length, 0)
    assert.equal(journalEvents.filter((event) => event.t === "agent_failed").length, 1)
  } finally {
    await fixture.dispose()
  }
})

test("provider execution enforces run-wide mutation cap across agents", async () => {
  const fixture = await workflowFixture(`export const meta = { name: "demo", description: "Valid test workflow" }
await agent("first", { label: "first" })
await agent("second", { label: "second" })
return "unreachable"
`)
  const provider = new FakeProviderAgentTurn(["first result", "second result"], [["a.ts"], ["b.ts"]])
  try {
    const result = await runWorkflowCommandApp(
      parseWorkflowProgrammaticCall("workflow", fixture.scriptPath, [{ ticket: 123 }, { maxAgents: 2, maxMutationFilesPerAgent: 2, maxMutationFilesPerRun: 1 }, {}]),
      {
        ...appEnv(),
        workflowExecutor: new IsolatedWorkflowExecutor({
          policy: parseWorkflowChildExecutionPolicy({}),
          providerAgentTurn: provider,
          callerSignal: new AbortController().signal,
        }),
      },
    )

    assert.equal(result.status, "completed")
    if (result.status !== "completed") return
    assert.equal(result.snapshot.status, "failed")
    assert.match(result.snapshot.error ?? "", /maxMutationFilesPerRun 1/)
    assert.equal(provider.requests.length, 2)
  } finally {
    await fixture.dispose()
  }
})

test("failed provider turns still count toward run-wide mutation caps", async () => {
  const fixture = await workflowFixture(`export const meta = { name: "demo", description: "Valid test workflow" }
try { await agent("first", { label: "first" }) } catch {}
try { await agent("second", { label: "second" }) } catch {}
await agent("third", { label: "third" })
return "unreachable"
`)
  const provider = new FakeProviderAgentTurn(
    ["first result", "second result"],
    [["a.ts"], ["b.ts"]],
    ["first failed", "second failed"],
  )
  try {
    const result = await runWorkflowCommandApp(
      parseWorkflowProgrammaticCall("workflow", fixture.scriptPath, [{ ticket: 123 }, { maxAgents: 3, maxMutationFilesPerAgent: 2, maxMutationFilesPerRun: 1 }, {}]),
      {
        ...appEnv(),
        workflowExecutor: new IsolatedWorkflowExecutor({
          policy: parseWorkflowChildExecutionPolicy({}),
          providerAgentTurn: provider,
          callerSignal: new AbortController().signal,
        }),
      },
    )

    assert.equal(result.status, "completed")
    if (result.status !== "completed") return
    assert.equal(result.snapshot.status, "failed")
    assert.match(result.snapshot.error ?? "", /maxMutationFilesPerRun 1/)
    assert.equal(provider.requests.length, 2)
  } finally {
    await fixture.dispose()
  }
})

test("provider mutation sidecar preserves run-wide caps across resume", async () => {
  const fixture = await workflowFixture(`export const meta = { name: "demo", description: "Valid test workflow" }
await agent("first", { label: "first" })
await agent("second", { label: "second" })
return "unreachable"
`)
  const journalPath = join(fixture.root, "mutation-resume.jsonl")
  try {
    const initialProvider = new FakeProviderAgentTurn(["first result", "second result"], [["a.ts"], ["b.ts"]])
    const initial = await runWorkflowCommandApp(
      parseWorkflowProgrammaticCall("workflow", fixture.scriptPath, [{ ticket: 123 }, { journal: journalPath, maxAgents: 2, maxMutationFilesPerAgent: 2, maxMutationFilesPerRun: 1 }, {}]),
      {
        ...appEnv(),
        processPort: processPort(11111),
        journalStoreFactory: new FileJournalStoreFactory(processPort(11111)),
        workflowExecutor: new IsolatedWorkflowExecutor({
          policy: parseWorkflowChildExecutionPolicy({}),
          providerAgentTurn: initialProvider,
          callerSignal: new AbortController().signal,
        }),
      },
    )
    assert.equal(initial.status, "completed")
    const fullLines = (await readFile(journalPath, "utf8")).trim().split("\n")
    const kept: string[] = []
    let firstCompletedNode = ""
    for (const line of fullLines) {
      kept.push(line)
      const event = parseJournalEventLine(line)
      if (event.t === "agent_completed") {
        firstCompletedNode = event.node
        break
      }
    }
    await writeFile(journalPath, `${kept.join("\n")}\n`, "utf8")
    await writeFile(`${journalPath}.mutations.jsonl`, `${JSON.stringify({ node: firstCompletedNode, attempt: 1, files: ["a.ts"] })}\n`, "utf8")

    const resumeProvider = new FakeProviderAgentTurn(["second result"], [["b.ts"]])
    const resumed = await runResumeCommandApp(
      parseResumeCliRequest(parseCliArgv(["resume", "--journal", journalPath, "--json", "--quiet"])),
      {
        ...appEnv(),
        processPort: processPort(22222),
        journalStoreFactory: new FileJournalStoreFactory(processPort(22222)),
        workflowExecutor: new IsolatedWorkflowExecutor({
          policy: parseWorkflowChildExecutionPolicy({}),
          providerAgentTurn: resumeProvider,
          callerSignal: new AbortController().signal,
        }),
      },
    )

    assert.equal(resumed.status, "completed")
    if (resumed.status !== "completed") return
    assert.equal(resumed.snapshot.status, "failed")
    assert.match(resumed.snapshot.error ?? "", /maxMutationFilesPerRun 1/)
    assert.equal(resumeProvider.requests.length, 1)
  } finally {
    await fixture.dispose()
  }
})

test("isolated mock execution emits hostcall journal drafts from parsed child requests", async () => {
  const fixture = await workflowFixture(`export const meta = { name: "demo", description: "Valid test workflow" }
phase("Plan")
log("hello")
const result = await agent("do the work", { label: "agent" })
return { result }
`)
  try {
    const result = await runWorkflowCommandApp(
      parseWorkflowProgrammaticCall("test", fixture.scriptPath, [{ ticket: 123 }, {}, {}]),
      appEnv(),
    )

    assert.equal(result.status, "completed")
    if (result.status !== "completed") return
    assert.equal(result.snapshot.phases[0]?.title, "Plan")
    assert.equal(result.snapshot.phases[0]?.nodes[0]?.label, "agent")
    assert.deepEqual(result.snapshot.logs, ["hello"])
    assert.deepEqual(result.snapshot.result, {
      result: {
        label: "agent",
        summary: "Mock workflow result.",
        prompt: "do the work",
      },
    })
    assert.equal(result.snapshot.totalTokens, 3)
  } finally {
    await fixture.dispose()
  }
})

test("workflow execution failure still commits a terminal failed run event", async () => {
  const fixture = await workflowFixture(`export const meta = { name: "demo", description: "Valid test workflow" }
await agent("do the work", { label: "agent" })
throw new Error("script failed")
`)
  try {
    const result = await runWorkflowCommandApp(
      parseWorkflowProgrammaticCall("test", fixture.scriptPath, [{ ticket: 123 }, {}, {}]),
      appEnv(),
    )

    assert.equal(result.status, "completed")
    if (result.status !== "completed") return
    assert.equal(result.snapshot.status, "failed")
    assert.equal(result.snapshot.agentCount, 1)
    assert.equal(result.snapshot.phases[0]?.nodes[0]?.state, "done")
    assert.notEqual(result.snapshot.error, undefined)
    if (result.snapshot.error === undefined) return
    assert.match(result.snapshot.error, /script failed/)
  } finally {
    await fixture.dispose()
  }
})

test("parent hostcall decisions allow multiple agents by default", async () => {
  const fixture = await workflowFixture(`export const meta = { name: "demo", description: "Valid test workflow" }
const first = await agent("first", { label: "first" })
const second = await agent("second", { label: "second" })
return { first, second }
`)
  try {
    const result = await runWorkflowCommandApp(
      parseWorkflowProgrammaticCall("test", fixture.scriptPath, [{ ticket: 123 }, {}, {}]),
      appEnv(),
    )

    assert.equal(result.status, "completed")
    if (result.status !== "completed") return
    assert.equal(result.snapshot.status, "done")
    assert.equal(result.snapshot.agentCount, 2)
    assert.deepEqual(result.snapshot.result, {
      first: {
        label: "first",
        summary: "Mock workflow result.",
        prompt: "first",
      },
      second: {
        label: "second",
        summary: "Mock workflow result.",
        prompt: "second",
      },
    })
  } finally {
    await fixture.dispose()
  }
})

test("parent hostcall decisions still enforce explicit agent caps", async () => {
  const fixture = await workflowFixture(`export const meta = { name: "demo", description: "Valid test workflow" }
await agent("first", { label: "first" })
await agent("second", { label: "second" })
return "unreachable"
`)
  try {
    const result = await runWorkflowCommandApp(
      parseWorkflowProgrammaticCall("test", fixture.scriptPath, [{ ticket: 123 }, { maxAgents: 1 }, {}]),
      appEnv(),
    )

    assert.equal(result.status, "completed")
    if (result.status !== "completed") return
    assert.equal(result.snapshot.status, "failed")
    assert.equal(result.snapshot.agentCount, 1)
    assert.notEqual(result.snapshot.error, undefined)
    if (result.snapshot.error === undefined) return
    assert.match(result.snapshot.error, /maxAgents 1/)
  } finally {
    await fixture.dispose()
  }
})

test("parent hostcall decisions allow multi-item parallel and pipeline calls by default", async () => {
  for (const [script, expected] of [
    [`export const meta = { name: "demo", description: "Valid test workflow" }
const results = await parallel([
  () => agent("first", { label: "first" }),
  () => agent("second", { label: "second" }),
])
return results.map((result) => result.label)
`, ["first", "second"]],
    [`export const meta = { name: "demo", description: "Valid test workflow" }
const results = await pipeline(["a", "b"], async (item) => agent(item, { label: item }))
return results.map((result) => result.label)
`, ["a", "b"]],
  ] as const) {
    const fixture = await workflowFixture(script)
    try {
      const result = await runWorkflowCommandApp(
        parseWorkflowProgrammaticCall("test", fixture.scriptPath, [{ ticket: 123 }, {}, {}]),
        appEnv(),
      )

      assert.equal(result.status, "completed")
      if (result.status !== "completed") return
      assert.equal(result.snapshot.status, "done")
      assert.equal(result.snapshot.agentCount, 2)
      assert.deepEqual(result.snapshot.result, expected)
    } finally {
      await fixture.dispose()
    }
  }
})

test("parent hostcall decisions enforce parallel and pipeline caps before agent work", async () => {
  for (const [script, message] of [
    [`export const meta = { name: "demo", description: "Valid test workflow" }
await parallel([
  () => agent("first", { label: "first" }),
  () => agent("second", { label: "second" }),
])
return "unreachable"
`, /maxParallelItems 1/],
    [`export const meta = { name: "demo", description: "Valid test workflow" }
await pipeline(["a", "b"], async (item) => agent(item, { label: item }))
return "unreachable"
`, /maxPipelineItems 1/],
  ] as const) {
    const fixture = await workflowFixture(script)
    try {
      const result = await runWorkflowCommandApp(
        parseWorkflowProgrammaticCall("test", fixture.scriptPath, [{ ticket: 123 }, { maxParallelItems: 1, maxPipelineItems: 1 }, {}]),
        appEnv(),
      )

      assert.equal(result.status, "completed")
      if (result.status !== "completed") return
      assert.equal(result.snapshot.status, "failed")
      assert.equal(result.snapshot.agentCount, 0)
      assert.notEqual(result.snapshot.error, undefined)
      if (result.snapshot.error === undefined) return
      assert.match(result.snapshot.error, message)
    } finally {
      await fixture.dispose()
    }
  }
})

test("workflow scripts can synchronously read unbounded budget", async () => {
  const fixture = await workflowFixture(`export const meta = { name: "demo", description: "Valid test workflow" }
await parallel([])
return {
  total: budget.total,
  spent: budget.spent(),
  remainingIsInfinity: budget.remaining() === Infinity,
}
`)
  try {
    const result = await runWorkflowCommandApp(
      parseWorkflowProgrammaticCall("test", fixture.scriptPath, [{ ticket: 123 }, {}, {}]),
      appEnv(),
    )

    assert.equal(result.status, "completed")
    if (result.status !== "completed") return
    assert.equal(result.snapshot.status, "done")
    assert.deepEqual(result.snapshot.result, {
      total: null,
      spent: 0,
      remainingIsInfinity: true,
    })
  } finally {
    await fixture.dispose()
  }
})

test("workflow scripts see explicit budget spend after agent responses", async () => {
  const fixture = await workflowFixture(`export const meta = { name: "demo", description: "Valid test workflow" }
const before = {
  total: budget.total,
  spent: budget.spent(),
  remaining: budget.remaining(),
}
await agent("abcd", { label: "agent" })
const after = {
  total: budget.total,
  spent: budget.spent(),
  remaining: budget.remaining(),
}
return { before, after }
`)
  try {
    const result = await runWorkflowCommandApp(
      parseWorkflowProgrammaticCall("test", fixture.scriptPath, [{ ticket: 123 }, { taskBudget: 10 }, {}]),
      appEnv(),
    )

    assert.equal(result.status, "completed")
    if (result.status !== "completed") return
    assert.equal(result.snapshot.status, "done")
    assert.deepEqual(result.snapshot.result, {
      before: { total: 10, spent: 0, remaining: 10 },
      after: { total: 10, spent: 1, remaining: 9 },
    })
  } finally {
    await fixture.dispose()
  }
})

test("explicit task budget stops future agent scheduling after observed spend reaches the ceiling", async () => {
  const fixture = await workflowFixture(`export const meta = { name: "demo", description: "Valid test workflow" }
await agent("first", { label: "first" })
await agent("second", { label: "second" })
await agent("third", { label: "third" })
return "unreachable"
`)
  const journalPath = join(fixture.root, "budget-overrun.jsonl")
  try {
    const result = await runWorkflowCommandApp(
      parseWorkflowProgrammaticCall("test", fixture.scriptPath, [{ ticket: 123 }, { journal: journalPath, taskBudget: 3 }, {}]),
      {
        ...appEnv(),
        journalStoreFactory: new FileJournalStoreFactory(processPort()),
      },
    )

    assert.equal(result.status, "completed")
    if (result.status !== "completed") return
    assert.equal(result.snapshot.status, "failed")
    assert.equal(result.snapshot.agentCount, 2)
    assert.match(result.snapshot.error ?? "", /workflow token budget exceeded \(4 \/ 3 tokens\)/)
    const journalEvents = (await readFile(journalPath, "utf8")).trim().split("\n").map((line) => parseJournalEventLine(line))
    assert.equal(journalEvents.filter((event) => event.t === "agent_completed").length, 2)
    assert.equal(journalEvents.some((event) => event.t === "agent_completed" && event.node !== undefined), true)
  } finally {
    await fixture.dispose()
  }
})

test("parent hostcall decisions execute child workflows through the resolver", async () => {
  const root = await makeTempDir("agent-loops-child-")
  const childPath = join(root, "child.ts")
  await writeFile(childPath, `export const meta = { name: "child", description: "Valid child workflow" }
const result = await agent("child work", { label: "child-agent" })
return { args, result }
`, "utf8")
  const fixture = await workflowFixture(`export const meta = { name: "demo", description: "Valid test workflow" }
const child = await workflow({ scriptPath: ${JSON.stringify(childPath)} }, { ticket: 123 })
return { child }
`)
  try {
    const result = await runWorkflowCommandApp(
      parseWorkflowProgrammaticCall("test", fixture.scriptPath, [{ ticket: 123 }, {}, {}]),
      {
        ...appEnv(),
        workflowExecutor: new IsolatedWorkflowExecutor({
          policy: parseWorkflowChildExecutionPolicy({}),
          childWorkflowResolver: new NodeWorkflowChildResolver(),
          callerSignal: new AbortController().signal,
        }),
      },
    )

    assert.equal(result.status, "completed")
    if (result.status !== "completed") return
    assert.equal(result.snapshot.status, "done")
    assert.equal(result.snapshot.agentCount, 1)
    assert.deepEqual(result.snapshot.result, {
      child: {
        args: { ticket: 123 },
        result: {
          label: "child-agent",
          summary: "Mock workflow result.",
          prompt: "child work",
        },
      },
    })
  } finally {
    await fixture.dispose()
    await rm(root, { recursive: true, force: true })
  }
})

test("parent hostcall decisions reject unapproved full access", async () => {
  const fixture = await workflowFixture(`export const meta = { name: "demo", description: "Valid test workflow" }
return agent("do the work", { label: "agent", isolation: "full-access" })
`)
  try {
    const result = await runWorkflowCommandApp(
      parseWorkflowProgrammaticCall("workflow", fixture.scriptPath, [{ ticket: 123 }, {}, {}]),
      {
        ...appEnv(),
        workflowExecutor: new IsolatedWorkflowExecutor({
          policy: parseWorkflowChildExecutionPolicy({}),
          providerAgentTurn: new FakeProviderAgentTurn(),
          callerSignal: new AbortController().signal,
        }),
      },
    )

    assert.equal(result.status, "completed")
    if (result.status !== "completed") return
    assert.equal(result.snapshot.status, "failed")
    assert.match(result.snapshot.error ?? "", /full-access isolation requires explicit approval/)
  } finally {
    await fixture.dispose()
  }
})

test("CLI test --mock emits current run-family envelope shape and persists the journal", async () => {
  const fixture = await workflowFixture()
  const cliPath = fileURLToPath(new URL("../src/cli.ts", import.meta.url))
  const result = spawnSync(process.execPath, [cliPath, "test", "--mock", fixture.scriptPath, "--json", "--quiet"], {
    cwd: fixture.root,
    encoding: "utf8",
  })
  try {
    assert.equal(result.status, 0, result.stderr)
    const envelope = record(parseWorkflowCliEnvelope(JSON.parse(result.stdout)))
    assert.deepEqual(Object.keys(envelope).sort(), ["budgetPlan", "command", "journalPath", "scriptPath", "snapshot"])
    assert.equal(envelope["command"], "test")
    const snapshot = record(envelope["snapshot"])
    assert.equal(snapshot["schemaVersion"], "workflow-snapshot/v2")
    assert.equal(snapshot["status"], "done")
    assert.equal(snapshot["workflowName"], "demo")
    assert.equal(record(envelope["budgetPlan"])["provider"], "mock")

    const pointerStatus = spawnSync(process.execPath, [cliPath, "status", "--json", "--quiet"], {
      cwd: fixture.root,
      encoding: "utf8",
    })
    assert.equal(pointerStatus.status, 0, pointerStatus.stderr)
    const status = record(parseWorkflowCliEnvelope(JSON.parse(pointerStatus.stdout)))
    assert.equal(status["command"], "status")
    assert.equal(record(status["status"])["runId"], snapshot["runId"])
    assert.equal(record(status["status"])["status"], "done")

    const listed = spawnSync(process.execPath, [cliPath, "list", "--json", "--quiet"], {
      cwd: fixture.root,
      encoding: "utf8",
    })
    assert.equal(listed.status, 0, listed.stderr)
    const listEnvelope = record(parseWorkflowCliEnvelope(JSON.parse(listed.stdout)))
    assert.equal(listEnvelope["command"], "list")
    const workflows = listEnvelope["workflows"]
    assert.ok(Array.isArray(workflows))
    assert.equal(workflows.length, 1)
    assert.equal(record(workflows[0])["runId"], snapshot["runId"])

    const resumed = spawnSync(process.execPath, [cliPath, "resume", "--json", "--quiet", "--no-input"], {
      cwd: fixture.root,
      encoding: "utf8",
    })
    assert.equal(resumed.status, 0, resumed.stderr)
    const resumeEnvelope = record(parseWorkflowCliEnvelope(JSON.parse(resumed.stdout)))
    assert.equal(resumeEnvelope["command"], "resume")
    assert.equal(record(resumeEnvelope["snapshot"])["runId"], snapshot["runId"])
    assert.equal(resumeEnvelope["journalPath"], envelope["journalPath"])

    const journalText = await readFile(String(envelope["journalPath"]), "utf8")
    assert.match(journalText, /"t":"runner_attached"/)
    assert.match(journalText, /"totalTokens":3/)
    const journalEvents = journalText.trim().split("\n").map((line) => parseJournalEventLine(line))
    assert.equal(journalEvents.filter((event) => event.t === "run_opened").length, 1)
  } finally {
    await fixture.dispose()
  }
})

test("resume replays completed journaled agents without a provider call", async () => {
  const fixture = await workflowFixture()
  const journalPath = join(fixture.root, "partial.jsonl")
  try {
    const initial = await runWorkflowCommandApp(
      parseWorkflowProgrammaticCall("test", fixture.scriptPath, [{ ticket: 123 }, { journal: journalPath }, {}]),
      {
        ...appEnv(),
        processPort: processPort(11111),
        journalStoreFactory: new FileJournalStoreFactory(processPort(11111)),
      },
    )
    assert.equal(initial.status, "completed")
    const fullText = await readFile(journalPath, "utf8")
    const partialLines = fullText.trim().split("\n").filter((line) => parseJournalEventLine(line).t !== "run_finished")
    await writeFile(journalPath, `${partialLines.join("\n")}\n`, "utf8")

    const provider = new FakeProviderAgentTurn()
    const resumed = await runResumeCommandApp(
      parseResumeCliRequest(parseCliArgv(["resume", "--journal", journalPath, "--json", "--quiet"])),
      {
        ...appEnv(),
        processPort: processPort(22222),
        journalStoreFactory: new FileJournalStoreFactory(processPort(22222)),
        workflowExecutor: new IsolatedWorkflowExecutor({
          policy: parseWorkflowChildExecutionPolicy({}),
          providerAgentTurn: provider,
          callerSignal: new AbortController().signal,
        }),
      },
    )

    assert.equal(resumed.status, "completed")
    if (resumed.status !== "completed") return
    assert.equal(resumed.snapshot.status, "done")
    assert.deepEqual(resumed.snapshot.result, {
      label: "agent",
      summary: "Mock workflow result.",
      prompt: "do the work",
    })
    assert.equal(provider.requests.length, 0)
    const journalEvents = (await readFile(journalPath, "utf8")).trim().split("\n").map((line) => parseJournalEventLine(line))
    assert.equal(journalEvents.filter((event) => event.t === "run_opened").length, 1)
    assert.equal(journalEvents.filter((event) => event.t === "agent_replayed").length, 1)
    assert.equal(journalEvents.filter((event) => event.t === "run_finished").length, 1)
  } finally {
    await fixture.dispose()
  }
})

test("resume passes recorded SDK thread binding for incomplete provider turns", async () => {
  const fixture = await workflowFixture()
  const journalPath = join(fixture.root, "partial-sdk.jsonl")
  try {
    const initialProvider = new FakeProviderAgentTurn(["live result"])
    const initial = await runWorkflowCommandApp(
      parseWorkflowProgrammaticCall("workflow", fixture.scriptPath, [{ ticket: 123 }, { journal: journalPath }, {}]),
      {
        ...appEnv(),
        processPort: processPort(11111),
        journalStoreFactory: new FileJournalStoreFactory(processPort(11111)),
        workflowExecutor: new IsolatedWorkflowExecutor({
          policy: parseWorkflowChildExecutionPolicy({}),
          providerAgentTurn: initialProvider,
          callerSignal: new AbortController().signal,
        }),
      },
    )
    assert.equal(initial.status, "completed")
    const fullText = await readFile(journalPath, "utf8")
    const partialLines = fullText.trim().split("\n").filter((line) => {
      const event = parseJournalEventLine(line)
      return event.t !== "agent_completed" && event.t !== "run_finished"
    })
    await writeFile(journalPath, `${partialLines.join("\n")}\n`, "utf8")

    const resumeProvider = new FakeProviderAgentTurn(["resumed result"])
    const resumed = await runResumeCommandApp(
      parseResumeCliRequest(parseCliArgv(["resume", "--journal", journalPath, "--json", "--quiet"])),
      {
        ...appEnv(),
        processPort: processPort(22222),
        journalStoreFactory: new FileJournalStoreFactory(processPort(22222)),
        workflowExecutor: new IsolatedWorkflowExecutor({
          policy: parseWorkflowChildExecutionPolicy({}),
          providerAgentTurn: resumeProvider,
          callerSignal: new AbortController().signal,
        }),
      },
    )

    assert.equal(resumed.status, "completed")
    if (resumed.status !== "completed") return
    assert.equal(resumed.snapshot.status, "done")
    assert.equal(resumed.snapshot.result, "resumed result")
    assert.equal(resumeProvider.requests.length, 1)
    assert.equal(resumeProvider.requests[0]?.threadId, "thread-live")
  } finally {
    await fixture.dispose()
  }
})

test("resume seeds budget spend from failed provider turns", async () => {
  const fixture = await workflowFixture(`export const meta = { name: "demo", description: "Valid test workflow" }
try { await agent("first", { label: "first" }) } catch {}
await agent("second", { label: "second" })
return "unreachable"
`)
  const journalPath = join(fixture.root, "partial-failed-budget.jsonl")
  try {
    const initialProvider = new FakeProviderAgentTurn(["first result"], [], ["first failed"])
    const initial = await runWorkflowCommandApp(
      parseWorkflowProgrammaticCall("workflow", fixture.scriptPath, [{ ticket: 123 }, { journal: journalPath, taskBudget: 7 }, {}]),
      {
        ...appEnv(),
        processPort: processPort(11111),
        journalStoreFactory: new FileJournalStoreFactory(processPort(11111)),
        workflowExecutor: new IsolatedWorkflowExecutor({
          policy: parseWorkflowChildExecutionPolicy({}),
          providerAgentTurn: initialProvider,
          callerSignal: new AbortController().signal,
        }),
      },
    )
    assert.equal(initial.status, "completed")
    assert.equal(initialProvider.requests.length, 1)
    const fullLines = (await readFile(journalPath, "utf8")).trim().split("\n")
    const kept: string[] = []
    for (const line of fullLines) {
      kept.push(line)
      if (parseJournalEventLine(line).t === "agent_failed") break
    }
    await writeFile(journalPath, `${kept.join("\n")}\n`, "utf8")

    const resumeProvider = new FakeProviderAgentTurn(["resumed first", "resumed second"])
    const resumed = await runResumeCommandApp(
      parseResumeCliRequest(parseCliArgv(["resume", "--journal", journalPath, "--json", "--quiet"])),
      {
        ...appEnv(),
        processPort: processPort(22222),
        journalStoreFactory: new FileJournalStoreFactory(processPort(22222)),
        workflowExecutor: new IsolatedWorkflowExecutor({
          policy: parseWorkflowChildExecutionPolicy({}),
          providerAgentTurn: resumeProvider,
          callerSignal: new AbortController().signal,
        }),
      },
    )

    assert.equal(resumed.status, "completed")
    if (resumed.status !== "completed") return
    assert.equal(resumed.snapshot.status, "failed")
    assert.match(resumed.snapshot.error ?? "", /workflow token budget exceeded \(7 \/ 7 tokens\)/)
    assert.equal(resumeProvider.requests.length, 0)
  } finally {
    await fixture.dispose()
  }
})

test("workflow runner writes periodic runner heartbeats while live", async () => {
  const fixture = await workflowFixture()
  const journalPath = join(fixture.root, "heartbeat-run.jsonl")
  const heartbeat = new FakeRunnerHeartbeat(2)
  try {
    const result = await runWorkflowCommandApp(
      parseWorkflowProgrammaticCall("test", fixture.scriptPath, [{ ticket: 123 }, { journal: journalPath }, {}]),
      {
        ...appEnv(),
        processPort: processPort(33333),
        journalStoreFactory: new FileJournalStoreFactory(processPort(33333)),
        runnerHeartbeat: heartbeat,
      },
    )

    assert.equal(result.status, "completed")
    assert.equal(heartbeat.stopped, true)
    const journalEvents = (await readFile(journalPath, "utf8")).trim().split("\n").map((line) => parseJournalEventLine(line))
    assert.equal(journalEvents.filter((event) => event.t === "runner_heartbeat" && event.pid === 33333).length, 3)
  } finally {
    await fixture.dispose()
  }
})

test("CLI --background launches a resume worker after run_opened is committed", async () => {
  const fixture = await workflowFixture()
  const cliPath = fileURLToPath(new URL("../src/cli.ts", import.meta.url))
  const result = spawnSync(process.execPath, [cliPath, "workflow", "--mock", fixture.scriptPath, "--background", "--json", "--quiet"], {
    cwd: fixture.root,
    encoding: "utf8",
  })
  try {
    assert.equal(result.status, 0, result.stderr)
    const envelope = record(parseWorkflowCliEnvelope(JSON.parse(result.stdout)))
    assert.equal(envelope["status"], "async_launched")
    assert.equal(envelope["command"], "workflow")
    assert.equal(envelope["workflowName"], "demo")
    assert.equal(record(envelope)["pid"] !== undefined, true)
    const journalEvents = (await readFile(String(envelope["journalPath"]), "utf8")).trim().split("\n").map((line) => parseJournalEventLine(line))
    assert.equal(journalEvents.filter((event) => event.t === "run_opened").length, 1)
    assert.equal(journalEvents.some((event) => event.t === "runner_attached"), true)
  } finally {
    await fixture.dispose()
  }
})

test("CLI entrypoint runs when invoked through a symlink", async () => {
  const root = await makeTempDir("agent-loops-cli-symlink-")
  try {
    const cliPath = fileURLToPath(new URL("../src/cli.ts", import.meta.url))
    const symlinkPath = join(root, "agent-loops-bin")
    await symlink(cliPath, symlinkPath)

    const result = spawnSync(process.execPath, [symlinkPath, "help"], {
      encoding: "utf8",
    })

    assert.equal(result.status, 0, result.stderr)
    assert.match(result.stdout, /agent-loops/)
    assert.match(result.stdout, /agent-loops workflow <script-or-name>/)
  } finally {
    await rm(root, { recursive: true, force: true })
  }
})

test("CLI --background --status-server returns status server handshake fields", async () => {
  const fixture = await workflowFixture()
  const cliPath = fileURLToPath(new URL("../src/cli.ts", import.meta.url))
  let workerPid = 0
  let statusServerPid = 0
  const result = spawnSync(process.execPath, [
    cliPath,
    "workflow",
    "--mock",
    fixture.scriptPath,
    "--background",
    "--status-server",
    "--status-port",
    "0",
    "--json",
    "--quiet",
  ], {
    cwd: fixture.root,
    encoding: "utf8",
  })
  try {
    assert.equal(result.status, 0, result.stderr)
    const envelope = record(parseWorkflowCliEnvelope(JSON.parse(result.stdout)))
    assert.equal(envelope["status"], "async_launched")
    assert.equal(typeof envelope["journalPath"], "string")
    assert.equal(typeof envelope["pid"], "number")
    assert.match(String(envelope["statusUrl"]), /^http:\/\/127\.0\.0\.1:\d+\/$/)
    assert.equal(typeof envelope["statusServerPid"], "number")
    workerPid = Number(envelope["pid"])
    statusServerPid = Number(envelope["statusServerPid"])
    const statusResponse = await fetch(new URL("/status.json", String(envelope["statusUrl"])))
    const statusPayload = record(await statusResponse.json())
    assert.equal(statusPayload["journalPath"], envelope["journalPath"])
    assert.equal(record(statusPayload["status"])["runId"], envelope["runId"])
    const portfile = record(JSON.parse(await readFile(`${envelope["journalPath"]}.serve.json`, "utf8")))
    assert.equal(portfile["url"], envelope["statusUrl"])
    assert.equal(portfile["pid"], envelope["statusServerPid"])
  } finally {
    if (statusServerPid > 0) {
      try {
        process.kill(statusServerPid, "SIGTERM")
        await waitForProcessExit(statusServerPid)
      } catch {
      }
    }
    if (workerPid > 0 && !await waitForProcessExit(workerPid)) {
      try {
        process.kill(workerPid, "SIGTERM")
        await waitForProcessExit(workerPid)
      } catch {
      }
    }
    await fixture.dispose()
  }
})

test("background status-server handshake failure does not launch the worker", async () => {
  const fixture = await workflowFixture()
  const journalPath = join(fixture.root, "status-fail.jsonl")
  const launcher = new FakeBackgroundProcessLauncher()
  try {
    await assert.rejects(
      () => runWorkflowCommandApp(
        parseWorkflowProgrammaticCall("workflow", fixture.scriptPath, [{ ticket: 123 }, {
          journal: journalPath,
          provider: "mock",
          background: true,
          statusServer: true,
        }, {}]),
        {
          ...appEnv(),
          processPort: processPort(44444),
          journalStoreFactory: new FileJournalStoreFactory(processPort(44444)),
          backgroundLauncher: launcher,
        },
      ),
      /status server pid 99998 did not publish a portfile/,
    )
    assert.equal(launcher.statusLaunches, 1)
    assert.equal(launcher.resumeLaunches, 0)
    assert.deepEqual(launcher.terminatedPids, [99998])
  } finally {
    await fixture.dispose()
  }
})

test("CLI draft writes a validated workflow scaffold", async () => {
  const root = await makeTempDir("agent-loops-draft-")
  const cliPath = fileURLToPath(new URL("../src/cli.ts", import.meta.url))
  const output = join(root, "drafted.ts")
  const result = spawnSync(process.execPath, [cliPath, "draft", "--goal", "Plan boundary refactor", "--output", output, "--json", "--quiet"], {
    cwd: root,
    encoding: "utf8",
  })
  try {
    assert.equal(result.status, 0, result.stderr)
    const envelope = record(parseWorkflowCliEnvelope(JSON.parse(result.stdout)))
    assert.deepEqual(Object.keys(envelope).sort(), ["command", "nextSteps", "scriptPath", "validation", "workflowName"])
    assert.equal(envelope["command"], "draft")
    assert.equal(envelope["workflowName"], "plan-boundary-refactor")
    assert.equal(envelope["scriptPath"], output)
    assert.equal(record(envelope["validation"])["ok"], true)
    const script = await readFile(output, "utf8")
    assert.match(script, /export const meta/)
    assert.match(script, /Plan boundary refactor/)
    assert.match(script, /Repository scout/)
    assert.match(script, /Workflow design/)
    assert.match(script, /Execution plan/)
    assert.match(script, /Adversarial review/)
    assert.match(script, /Facts and Consequences/)
    assert.match(script, /barrier/)
    assert.match(script, /pipeline/)
    assert.match(script, /Default to fail/)
    assert.doesNotMatch(script, /Parallel analysis/)
  } finally {
    await rm(root, { recursive: true, force: true })
  }
})

test("serve app emits a status envelope and writes a durable portfile", async () => {
  const fixture = await workflowFixture()
  const cliPath = fileURLToPath(new URL("../src/cli.ts", import.meta.url))
  const run = spawnSync(process.execPath, [cliPath, "test", "--mock", fixture.scriptPath, "--json", "--quiet"], {
    cwd: fixture.root,
    encoding: "utf8",
  })
  try {
    assert.equal(run.status, 0, run.stderr)
    const runEnvelope = record(parseWorkflowCliEnvelope(JSON.parse(run.stdout)))
    const statusServer = new FakeStatusServer()
    const uiRoot = join(fixture.root, "status-ui")
    await mkdir(uiRoot, { recursive: true })
    await writeFile(join(uiRoot, "index.html"), "<!doctype html><div id=\"root\"></div>", "utf8")
    const serve = await runServeCommandApp(
      parseServeCliRequest(parseCliArgv(["serve", "--journal", String(runEnvelope["journalPath"]), "--port", "0", "--json"])),
      {
        journalReader: new FileJournalReader(),
        processPort: processPort(),
        servePortfileStore: new FileServePortfileStore(),
        statusServer,
        statusUiRootDirectory: uiRoot,
        workflowScriptSourceStore: { read: async (path: string) => readFile(path, "utf8") },
      },
    )
    assert.deepEqual(Object.keys(serve.envelope).sort(), ["command", "journalPath", "url"])
    assert.equal(serve.envelope.command, "serve")
    assert.equal(serve.envelope.journalPath, runEnvelope["journalPath"])
    assert.equal(serve.envelope.url, "http://127.0.0.1:43210/")
    assert.equal(statusServer.uiRootDirectory, uiRoot)
    assert.equal(record(JSON.parse(statusServer.prettyPayload))["journalPath"], runEnvelope["journalPath"])
    assert.equal(record(record(JSON.parse(statusServer.prettyPayload))["status"])["runId"], record(runEnvelope["snapshot"])["runId"])

    const portfile = JSON.parse(await readFile(`${runEnvelope["journalPath"]}.serve.json`, "utf8"))
    assert.equal(portfile.url, serve.envelope.url)
    assert.equal(portfile.pid, 12345)
    await serve.close()
  } finally {
    await fixture.dispose()
  }
})

test("node status server reloads live payloads for status reads", async () => {
  let version = 1
  const uiRoot = await makeTempDir("agent-loops-ui-")
  await mkdir(join(uiRoot, "assets"), { recursive: true })
  await writeFile(join(uiRoot, "index.html"), "<!doctype html><div id=\"root\"></div><script type=\"module\" src=\"/assets/app.js\"></script>", "utf8")
  await writeFile(join(uiRoot, "assets", "app.js"), "window.__agentLoopsStatusUi = true\n", "utf8")
  const server = await new NodeStatusServerPort().start({
    host: "127.0.0.1",
    port: 0,
    livePollMs: 25,
    parseRoute: parseStatusServerRoute,
    ui: { rootDirectory: uiRoot },
    async loadPayload() {
      const text = JSON.stringify({ version })
      return { compactPayload: text, prettyPayload: text }
    },
  })
  try {
    const address = parseServerAddress(server.address)
    const first = record(await (await fetch(new URL("/status.json", address.url))).json())
    version = 2
    const second = record(await (await fetch(new URL("/status.json", address.url))).json())
    assert.equal(first["version"], 1)
    assert.equal(second["version"], 2)
    const indexResponse = await fetch(new URL("/", address.url))
    assert.equal(indexResponse.status, 200)
    assert.match(await indexResponse.text(), /<div id="root"><\/div>/)
    const fallbackResponse = await fetch(new URL("/phase/1", address.url))
    assert.equal(fallbackResponse.status, 200)
    assert.match(await fallbackResponse.text(), /<div id="root"><\/div>/)
    const assetResponse = await fetch(new URL("/assets/app.js", address.url))
    assert.equal(assetResponse.status, 200)
    assert.match(assetResponse.headers.get("content-type") ?? "", /application\/javascript/)
    assert.match(await assetResponse.text(), /__agentLoopsStatusUi/)
    const traversalResponse = await fetch(new URL("/%2e%2e/package.json", address.url))
    assert.equal(traversalResponse.status, 404)
  } finally {
    await server.close()
    await rm(uiRoot, { recursive: true, force: true })
  }
})

test("CLI validate rejects incompatible scripts with validation exit code", async () => {
  const root = await makeTempDir("agent-loops-invalid-")
  const cliPath = fileURLToPath(new URL("../src/cli.ts", import.meta.url))
  const scriptPath = join(root, "invalid.ts")
  await writeFile(scriptPath, "return { ok: true }\n", "utf8")
  const result = spawnSync(process.execPath, [cliPath, "validate", scriptPath, "--json", "--quiet"], {
    cwd: root,
    encoding: "utf8",
  })
  try {
    assert.equal(result.status, 6)
    assert.match(result.stderr, /Workflow compatibility failed/)
    const payload = JSON.parse(result.stderr.trim().split("\n").at(-1) ?? "{}")
    assert.equal(payload.code, "validation")
    assert.equal(payload.exitCode, 6)
  } finally {
    await rm(root, { recursive: true, force: true })
  }
})

test("CLI validate accepts compatible scripts without journal writes or execution", async () => {
  const fixture = await workflowFixture()
  const cliPath = fileURLToPath(new URL("../src/cli.ts", import.meta.url))
  const result = spawnSync(process.execPath, [cliPath, "validate", fixture.scriptPath, "--json", "--quiet"], {
    cwd: fixture.root,
    encoding: "utf8",
  })
  try {
    assert.equal(result.status, 0, result.stderr)
    const envelope = record(parseWorkflowCliEnvelope(JSON.parse(result.stdout)))
    assert.equal(envelope["command"], "validate")
    assert.equal(envelope["workflowName"], "demo")
    assert.equal(envelope["scriptPath"], fixture.scriptPath)
    assert.equal(record(envelope["validation"])["ok"], true)
    await assert.rejects(() => readdir(join(fixture.root, ".agent-loops-runs")))
  } finally {
    await fixture.dispose()
  }
})

test("CLI validate rejects malformed meta before preparation uses it", async () => {
  const root = await makeTempDir("agent-loops-invalid-meta-")
  const cliPath = fileURLToPath(new URL("../src/cli.ts", import.meta.url))
  const scriptPath = join(root, "invalid-meta.ts")
  await writeFile(scriptPath, `export const meta = { name: 123, description: "Invalid workflow" }
return agent("do the work", { label: "agent" })
`, "utf8")
  const result = spawnSync(process.execPath, [cliPath, "validate", scriptPath, "--json", "--quiet"], {
    cwd: root,
    encoding: "utf8",
  })
  try {
    assert.equal(result.status, 6)
    assert.match(result.stderr, /workflow meta requires string field name/)
    const payload = JSON.parse(result.stderr.trim().split("\n").at(-1) ?? "{}")
    assert.equal(payload.code, "validation")
    assert.equal(payload.exitCode, 6)
  } finally {
    await rm(root, { recursive: true, force: true })
  }
})

function record(value: unknown): Record<string, unknown> {
  assert.equal(typeof value, "object")
  assert.notEqual(value, null)
  assert.equal(Array.isArray(value), false)
  return value as Record<string, unknown>
}

async function waitForProcessExit(pid: number): Promise<boolean> {
  for (let attempt = 0; attempt < 20; attempt += 1) {
    try {
      process.kill(pid, 0)
    } catch {
      return true
    }
    await new Promise((resolveWait) => setTimeout(resolveWait, 25))
  }
  return false
}

function processPort(pid = 12345) {
  return {
    pid() {
      return pid
    },
    cwd() {
      return "/tmp"
    },
    probePid() {
    },
  }
}

async function workflowFixture(source?: string | undefined): Promise<{ root: string; scriptPath: string; dispose(): Promise<void> }> {
  const root = await makeTempDir("agent-loops-")
  const scriptPath = join(root, "demo.ts")
  await writeFile(scriptPath, source === undefined ? validWorkflowScript() : source, "utf8")
  return {
    root,
    scriptPath,
    async dispose() {
      await rm(root, { recursive: true, force: true })
    },
  }
}

function validWorkflowScript(): string {
  return `export const meta = { name: "demo", description: "Valid test workflow" }
return agent("do the work", { label: "agent" })
`
}

class FakeProviderAgentTurn implements ProviderAgentTurnPort {
  readonly requests: Parameters<ProviderAgentTurnPort["runAgentTurn"]>[0][] = []
  readonly #messages: readonly string[]
  readonly #mutationFiles: readonly (readonly string[])[]
  readonly #failures: readonly (string | undefined)[]

  constructor(messages?: readonly string[] | undefined, mutationFiles?: readonly (readonly string[])[] | undefined, failures?: readonly (string | undefined)[] | undefined) {
    this.#messages = messages === undefined ? ["live result"] : messages
    this.#mutationFiles = mutationFiles === undefined ? [] : mutationFiles
    this.#failures = failures === undefined ? [] : failures
  }

  async runAgentTurn(request: Parameters<ProviderAgentTurnPort["runAgentTurn"]>[0]): ReturnType<ProviderAgentTurnPort["runAgentTurn"]> {
    const index = this.requests.length
    this.requests.push(request)
    const text = this.#messages[index] === undefined ? "live result" : this.#messages[index]
    const mutationFiles = this.#mutationFiles[index]
    const failure = this.#failures[index]
    const events = [
      { value: { type: "thread.started", thread_id: "thread-live" } },
      ...(failure === undefined ? [{ value: { type: "item.completed", item: { id: "item-1", type: "agent_message", text } } }] : []),
      ...(mutationFiles === undefined ? [] : [{
        value: {
          type: "item.completed",
          item: {
            id: `file-change-${index}`,
            type: "file_change",
            changes: mutationFiles.map((path) => ({ path, kind: "updated" })),
            status: "completed",
          },
        },
      }]),
      ...(failure === undefined ? [] : [{ value: { type: "turn.failed", error: { message: failure } } }]),
      {
        value: {
          type: "turn.completed",
          usage: { input_tokens: 3, cached_input_tokens: 0, output_tokens: 4, reasoning_output_tokens: 0 },
        },
      },
    ]
    for (const event of events) await request.onStreamEvent(event)
    return {
      durationMs: 12,
      events,
    }
  }
}

class FakeStatusServer implements StatusServerPort {
  prettyPayload = ""
  uiRootDirectory = ""

  async start(input: Parameters<StatusServerPort["start"]>[0]): ReturnType<StatusServerPort["start"]> {
    const payload = await input.loadPayload()
    this.prettyPayload = payload.prettyPayload
    this.uiRootDirectory = input.ui.rootDirectory
    return {
      address: { address: "127.0.0.1", port: 43210 },
      async close() {},
    }
  }
}

class FakeBackgroundProcessLauncher implements BackgroundProcessLauncher {
  resumeLaunches = 0
  statusLaunches = 0
  terminatedPids: number[] = []

  async launchResumeWorker(): ReturnType<BackgroundProcessLauncher["launchResumeWorker"]> {
    this.resumeLaunches += 1
    return { pid: 99999 }
  }

  async launchStatusServer(): ReturnType<BackgroundProcessLauncher["launchStatusServer"]> {
    this.statusLaunches += 1
    return { pid: 99998 }
  }

  async terminate(input: Parameters<BackgroundProcessLauncher["terminate"]>[0]): ReturnType<BackgroundProcessLauncher["terminate"]> {
    this.terminatedPids.push(input.pid)
  }

  async wait(): ReturnType<BackgroundProcessLauncher["wait"]> {
  }
}

class FakeRunnerHeartbeat implements RunnerHeartbeatPort {
  readonly #ticks: number
  stopped = false

  constructor(ticks = 0) {
    this.#ticks = ticks
  }

  async start(input: Parameters<RunnerHeartbeatPort["start"]>[0]): ReturnType<RunnerHeartbeatPort["start"]> {
    for (let index = 0; index < this.#ticks; index += 1) await input.writeHeartbeat()
    return {
      stop: async () => {
        this.stopped = true
      },
    }
  }
}
