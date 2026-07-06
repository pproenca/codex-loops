import assert from "node:assert/strict"
import { test } from "node:test"

import { parseCliArgv, parseCliRequest, parseWorkflowCliEnvelope } from "../src/trust/cli.ts"
import { CliUsageError, parseCliFailure } from "../src/trust/cli-error.ts"
import { parseContainmentPolicy, parseRunnerHeartbeatPolicy } from "../src/trust/containment.ts"
import { parseGitRootProbe, parseGitStatusProbe, parseGitWorktreeFacts } from "../src/trust/git.ts"
import { parseAgentHostcall, parseLogHostcall, parsePhaseHostcall, parseWorkflowChildLine, parseWorkflowHostcall } from "../src/trust/hostcall.ts"
import { parseJournalEventLine, parseJournalText } from "../src/trust/journal-event.ts"
import { parseJsonValue } from "../src/trust/json.ts"
import { parseProviderStreamEvent } from "../src/trust/provider-event.ts"
import { parseStatusServerRoute } from "../src/trust/status-server-route.ts"

const journalLimits = {
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

const journalBudgetPlan = {
  provider: "mock",
  limits: journalLimits,
  expectedAgents: { minimum: 1, maximum: 1, basis: "test" },
  workload: {
    scopeKind: "bounded",
    batchable: false,
    runCompleteness: "full",
    basis: "test",
  },
  modelPolicySummary: {
    defaultEffort: "medium",
    minEffort: "medium",
    maxEffort: "xhigh",
    disallowedEfforts: [],
  },
  writeScope: { posture: "read-only", summary: "test" },
  tokenWarning: "test",
}

const journalRuntimeContract = {
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
  resume: {
    cacheKey: "runId+phaseTitle+label+promptHash+schemaHash+optionsHash",
    completedNodesReplayFromJournal: true,
  },
  remote: { supported: false, reason: "test" },
}

test("trust parses CLI requests as closed records", () => {
  const request = parseCliRequest({ command: "workflow", args: ["flow.ts"], flags: { approved: true } })
  assert.equal(request.command, "workflow")
  assert.deepEqual(request.args, ["flow.ts"])
  assert.throws(() => parseCliRequest({ command: "workflow", args: [], flags: {}, forged: true }))
})

test("trust parses argv into positionals and flags at ingress", () => {
  const request = parseCliArgv(["workflow", "flow.ts", "--args", "{\"x\":1}", "--approved", "--provider=mock"])
  assert.equal(request.command, "workflow")
  assert.deepEqual(request.args, ["flow.ts"])
  assert.deepEqual(request.flags, { args: "{\"x\":1}", approved: true, provider: "mock" })
})

test("trust rejects argv that violates the command contract", () => {
  assert.throws(() => parseCliArgv(["status", "unexpected"]))
  assert.throws(() => parseCliArgv(["workflow", "flow.ts", "--unknown"]))
  assert.throws(() => parseCliArgv(["workflow", "flow.ts", "--approved=true"]))
  assert.throws(() => parseCliArgv(["workflow", "flow.ts", "--args"]))
})

test("trust rejects removed journal flag on every command", () => {
  for (const command of ["draft", "validate", "test", "workflow", "run", "resume", "inspect", "status", "list", "serve"] as const) {
    assert.throws(
      () => parseCliArgv([command, "--journal", "run-1"]),
      /--journal was removed; use --run-id/,
    )
  }
})

test("trust classifies CLI usage errors separately from runtime errors", () => {
  assert.deepEqual(parseCliFailure(new CliUsageError("bad flag")), {
    exitCode: 2,
    message: "bad flag",
    payload: { code: "usage", exitCode: 2, message: "bad flag" },
  })
  assert.deepEqual(parseCliFailure(new Error("boom")), {
    exitCode: 1,
    message: "boom",
    payload: { code: "runtime", exitCode: 1, message: "boom" },
  })
})

test("trust parses CLI output envelopes as closed records", () => {
  assert.equal(parseWorkflowCliEnvelope({
    command: "draft",
    workflowName: "demo",
    scriptPath: "demo.ts",
    validation: { ok: true, findings: [] },
    nextSteps: ["agent-loops validate demo.ts"],
  }).command, "draft")
  assert.throws(() => parseWorkflowCliEnvelope({
    command: "draft",
    workflowName: "demo",
    scriptPath: "demo.ts",
    validation: { ok: true, findings: [] },
    nextSteps: [],
    forged: true,
  }))
})

test("trust applies containment defaults at ingress", () => {
  const policy = parseContainmentPolicy({})
  assert.equal(policy.wallTimeoutMs, 30 * 60_000)
  assert.equal(policy.idleTimeoutMs, 5 * 60_000)
  assert.equal(parseRunnerHeartbeatPolicy({}).intervalMs, 10_000)
})

test("trust rejects non-json payloads", () => {
  assert.deepEqual(parseJsonValue({ ok: ["yes", 1, null] }), { ok: ["yes", 1, null] })
  assert.throws(() => parseJsonValue({ bad: Number.NaN }))
})

test("trust parses hostcalls as closed records", () => {
  assert.deepEqual(parsePhaseHostcall(["Plan"]), { title: "Plan" })
  assert.deepEqual(parseLogHostcall(["hello"]), { message: "hello" })
  assert.deepEqual(parseAgentHostcall(["prompt", { label: "a", isolation: "read-only" }]), {
    prompt: "prompt",
    options: { label: "a", isolation: "read-only" },
  })
  assert.deepEqual(parseAgentHostcall(["prompt"]), {
    prompt: "prompt",
    options: { isolation: "read-only" },
  })
  assert.deepEqual(parseWorkflowHostcall(["child", { ok: true }]), {
    ref: { t: "named", value: "child" },
    args: { ok: true },
  })

  assert.throws(() => parsePhaseHostcall([123]))
  assert.throws(() => parseLogHostcall(["hello", "extra"]))
  assert.throws(() => parseAgentHostcall(["prompt", { label: "a", injected: true }]))
  assert.throws(() => parseAgentHostcall(["prompt", { isolation: "shell" }]))
  assert.throws(() => parseWorkflowHostcall([{ scriptPath: "" }]))
})

test("trust rejects hostcall schemas that are not JSON values", () => {
  assert.throws(() => parseAgentHostcall(["prompt", { schema: { type: Number.NaN } }]))
})

test("trust parses git subprocess probes", () => {
  assert.deepEqual(parseGitRootProbe({ exitCode: 0, signal: null, stdout: "/repo\n", stderr: "" }), { t: "repo", root: "/repo" })
  assert.deepEqual(parseGitRootProbe({ exitCode: 128, signal: null, stdout: "", stderr: "not repo" }), { t: "not_repo" })
  assert.deepEqual(parseGitStatusProbe({ exitCode: 0, signal: null, stdout: "", stderr: "" }), { dirty: false })
  assert.deepEqual(parseGitStatusProbe({ exitCode: 0, signal: null, stdout: "?? file\u0000", stderr: "" }), { dirty: true })
  assert.deepEqual(parseGitWorktreeFacts({ t: "repo", root: "/repo", dirty: true }), { t: "repo", root: "/repo", dirty: true })
  assert.throws(() => parseGitWorktreeFacts({ t: "repo", root: "", dirty: true }))
})

test("trust parses status server routes and rejects traversal", () => {
  assert.deepEqual(parseStatusServerRoute("/status.json"), { t: "status-json" })
  assert.deepEqual(parseStatusServerRoute("/events"), { t: "events" })
  assert.deepEqual(parseStatusServerRoute("/"), { t: "index" })
  assert.deepEqual(parseStatusServerRoute("/phase/1"), { t: "index" })
  assert.deepEqual(parseStatusServerRoute("/assets/app.js"), { t: "asset", path: "assets/app.js" })
  assert.deepEqual(parseStatusServerRoute("/favicon.ico"), { t: "asset", path: "favicon.ico" })
  assert.deepEqual(parseStatusServerRoute("/../package.json"), { t: "not-found" })
  assert.deepEqual(parseStatusServerRoute("/%2e%2e/package.json"), { t: "not-found" })
  assert.deepEqual(parseStatusServerRoute("/api/status"), { t: "not-found" })
})

test("trust maps SDK events into provider-domain events", () => {
  const thread = parseProviderStreamEvent({ type: "thread.started", thread_id: "thread-1" })
  assert.deepEqual(thread, { t: "thread_bound", threadId: "thread-1" })

  const usage = parseProviderStreamEvent({
    type: "turn.completed",
    usage: { input_tokens: 3, cached_input_tokens: 0, output_tokens: 5, reasoning_output_tokens: 0 },
  })
  assert.deepEqual(usage, { t: "usage_observed", inputTokens: 3, outputTokens: 5 })

  const files = parseProviderStreamEvent({
    type: "item.completed",
    item: {
      id: "files-1",
      type: "file_change",
      status: "completed",
      changes: [
        { path: "a.ts", kind: "created" },
        { path: "b.ts", kind: "updated" },
      ],
    },
  })
  assert.deepEqual(files, {
    t: "file_mutations_observed",
    files: [
      { path: "a.ts", operation: "created" },
      { path: "b.ts", operation: "updated" },
    ],
  })

  assert.deepEqual(parseProviderStreamEvent({
    type: "item.completed",
    item: {
      id: "message-1",
      type: "agent_message",
      text: "done",
      aggregated_output: [{ type: "text", text: "done" }],
    },
  }), { t: "message_observed", text: "done" })

  assert.throws(() => parseProviderStreamEvent({ type: "thread.started", thread_id: "" }))
})

test("trust parses workflow child protocol lines as closed records", () => {
  assert.deepEqual(parseWorkflowChildLine(JSON.stringify({ t: "hostcall", id: 1, op: "phase", args: ["Plan"] })), {
    t: "hostcall",
    id: 1,
    op: "phase",
    call: { title: "Plan" },
  })
  assert.deepEqual(parseWorkflowChildLine(JSON.stringify({ t: "done", value: { ok: true } })), {
    t: "done",
    value: { ok: true },
  })
  assert.throws(() => parseWorkflowChildLine(JSON.stringify({ t: "hostcall", id: 1, op: "phase", args: [1] })))
  assert.throws(() => parseWorkflowChildLine(JSON.stringify({ t: "done", value: { ok: true }, extra: true })))
})

test("trust parses journal lines as closed journal records", () => {
  const line = JSON.stringify({
    seq: 1,
    t: "run_opened",
    schema: "agent-loops/journal@2",
    runId: "run-1",
    workflowName: "wf",
    scriptPath: "/tmp/wf.ts",
    scriptSha256: "abc",
    args: { ticket: 123 },
    provider: "mock",
    budgetPlan: journalBudgetPlan,
    limits: journalLimits,
    runtimeContract: journalRuntimeContract,
  })

  const event = parseJournalEventLine(line)
  assert.equal(event.t, "run_opened")
  assert.equal(event.runId, "run-1")
})

test("trust rejects forged journal fields and malformed event payloads", () => {
  assert.throws(() => parseJournalEventLine(JSON.stringify({
    seq: 1,
    t: "runner_heartbeat",
    pid: 12,
    injected: true,
  })))
  assert.throws(() => parseJournalEventLine(JSON.stringify({
    seq: 1,
    t: "agent_completed",
    node: "n1",
    attempt: 1,
    result: null,
    tokens: -1,
    toolCalls: 0,
    durationMs: 0,
    source: "mock",
  })))
  assert.throws(() => parseJournalEventLine(JSON.stringify({
    seq: 1,
    t: "run_opened",
    schema: "agent-loops/journal@2",
    runId: "run-1",
    workflowName: "wf",
    scriptPath: "/tmp/wf.ts",
    scriptSha256: "abc",
    args: {},
    provider: "mock",
    budgetPlan: { provider: "mock" },
    limits: journalLimits,
    runtimeContract: journalRuntimeContract,
  })))
  assert.throws(() => parseJournalEventLine(JSON.stringify({
    seq: 1,
    t: "run_opened",
    schema: "agent-loops/journal@2",
    runId: "run-1",
    workflowName: "wf",
    scriptPath: "/tmp/wf.ts",
    scriptSha256: "abc",
    args: {},
    provider: "mock",
    budgetPlan: journalBudgetPlan,
    limits: journalLimits,
    runtimeContract: { remote: { supported: false } },
  })))
})

test("trust rejects journal streams that are not ordered records", () => {
  assert.throws(() => parseJournalText(`${JSON.stringify({ seq: 2, t: "log_emitted", message: "first" })}\n`))

  const opened = {
    seq: 1,
    t: "run_opened",
    schema: "agent-loops/journal@2",
    runId: "run-1",
    workflowName: "wf",
    scriptPath: "/tmp/wf.ts",
    scriptSha256: "abc",
    args: {},
    provider: "mock",
    budgetPlan: journalBudgetPlan,
    limits: journalLimits,
    runtimeContract: journalRuntimeContract,
  }
  assert.throws(() => parseJournalText(`${JSON.stringify(opened)}\n${JSON.stringify({ seq: 3, t: "log_emitted", message: "gap" })}\n`))
  assert.throws(() => parseJournalText(`${JSON.stringify(opened)}\n${JSON.stringify({ seq: 2, t: "run_finished", status: "done", totalTokens: 0, totalToolCalls: 0, durationMs: 0 })}\n${JSON.stringify({ seq: 3, t: "log_emitted", message: "late" })}\n`))
})
