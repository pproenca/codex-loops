import type { Proven } from "../domain/brand.ts"
import type { BackgroundStatusServerMode, CliRequest, DraftCommandRequest, JournalEventDraft, JournalRunCandidate, JournalListRequest, JournalMutationRecord, JournalQueryRequest, JournalReadResult, ResumeCommandRequest, ServeCommandRequest, WorkflowApiResult, WorkflowCommandRequest, WorkflowExecutionOutcome, WorkflowListEntry } from "../domain/contracts.ts"
import { planDraftWorkflow } from "../core/draft-workflow.ts"
import { foldJournal, toWorkflowSnapshot, toWorkflowStatusSummary } from "../core/journal-projection.ts"
import { prepareWorkflowRun, runnerAttachMode, selectResumeWorkflowProvider, selectWorkflowProvider } from "../core/prepare-run.ts"
import { decideResumeFromJournal, hasRunnerAttached, prepareWorkflowResumeRun } from "../core/resume-journal.ts"
import { buildServeStatusPayload, extractStaticAgentGoals } from "../core/serve-status.ts"
import { CLI_VERSION } from "../domain/cli-contract.ts"
import type { BackgroundProcessLauncher, DraftWorkflowStore, JournalDirectoryPort, JournalReader, JournalStore, JournalStoreFactory, ProcessPort, RunnerHeartbeatPort, ServeSessionStore, StatusServerPort, WorkflowExecutor, WorkflowRunPreparer, WorkflowScriptLocator, WorkflowScriptSourceStore } from "../ports/index.ts"
import { parseErrorMessage } from "../trust/cli-error.ts"
import { parseDraftCliRequest } from "../trust/draft-command.ts"
import { parseJournalText } from "../trust/journal-event.ts"
import { parseJournalMutationText } from "../trust/journal-mutations.ts"
import { parseJournalListCliRequest, parseJournalQueryCliRequest } from "../trust/journal-query.ts"
import { parseNodeErrorFacts } from "../trust/node-error.ts"
import { parseResumeCliRequest } from "../trust/resume-command.ts"
import { parseServerAddress } from "../trust/server-address.ts"
import { parseServeCliRequest } from "../trust/serve-command.ts"
import { parseServeSessionText } from "../trust/serve-session.ts"
import { parseStatusServerRoute } from "../trust/status-server-route.ts"
import { parseWorkflowCommandCliRequest } from "../trust/workflow-command.ts"
import { parseCompatibleWorkflowScriptSource } from "../trust/workflow-script.ts"

export type WorkflowAppEnvironment = {
  readonly journalReader: JournalReader
  readonly journalDirectory: JournalDirectoryPort
  readonly journalStoreFactory: JournalStoreFactory
  readonly serveSessionStore: ServeSessionStore
  readonly draftWorkflowStore: DraftWorkflowStore
  readonly processPort: ProcessPort
  readonly workflowScriptLocator: WorkflowScriptLocator
  readonly workflowPreparer: WorkflowRunPreparer
  readonly workflowScriptSourceStore: WorkflowScriptSourceStore
  readonly workflowExecutor: WorkflowExecutor
  readonly backgroundLauncher: BackgroundProcessLauncher
  readonly runnerHeartbeat: RunnerHeartbeatPort
}

export type JournalQueryEnvironment = {
  readonly journalReader: JournalReader
}

export type ServeAppEnvironment = JournalQueryEnvironment & {
  readonly processPort: ProcessPort
  readonly serveSessionStore: ServeSessionStore
  readonly statusServer: StatusServerPort
  readonly statusUiRootDirectory: string
  readonly workflowScriptSourceStore: WorkflowScriptSourceStore
}

export type ServeAppResult = {
  readonly envelope: { readonly command: "serve"; readonly runId: string; readonly databasePath: string; readonly url: string }
  readonly close: () => Promise<void>
}

export async function runWorkflowApp(request: Proven<CliRequest>, env: WorkflowAppEnvironment): Promise<WorkflowApiResult> {
  switch (request.command) {
    case "validate":
      return runValidateCommandApp(parseWorkflowCommandCliRequest(request), env)
    case "test":
    case "workflow":
    case "run":
      return runWorkflowCommandApp(parseWorkflowCommandCliRequest(request), env)
    case "resume":
      return runResumeCommandApp(parseResumeCliRequest(request), env)
    case "inspect":
    case "status":
      return runJournalQueryApp(parseJournalQueryCliRequest(request), env)
    case "list":
      return runJournalListApp(parseJournalListCliRequest(request), env)
    case "draft":
      return runDraftCommandApp(parseDraftCliRequest(request), env)
    case "help":
    case "serve":
      return { status: "not_ready", command: request.command }
  }
}

export async function runServeCommandApp(request: Proven<ServeCommandRequest>, env: ServeAppEnvironment): Promise<ServeAppResult> {
  const resolved = await readRun(request.runId, env)
  const server = await env.statusServer.start({
    host: request.host,
    port: request.port,
    livePollMs: request.livePollMs,
    loadPayload: async () => {
      const latest = await readRun(resolved.runId, env)
      const latestGoals = await readStaticAgentGoals(latest.read, env)
      const latestPayload = buildServeStatusPayload({ read: latest.read, databasePath: latest.databasePath, eventLimit: request.eventLimit, agentGoals: latestGoals })
      return { compactPayload: latestPayload.compactPayload, prettyPayload: latestPayload.prettyPayload }
    },
    parseRoute: parseStatusServerRoute,
    ui: { rootDirectory: env.statusUiRootDirectory },
  })
  const address = parseServerAddress(server.address)
  await env.serveSessionStore.writeSession({ runId: resolved.runId, url: address.url, pid: env.processPort.pid() })
  return {
    envelope: { command: request.command, runId: resolved.runId, databasePath: resolved.databasePath, url: address.url },
    async close() {
      await server.close()
      await env.serveSessionStore.removeSession(resolved.runId)
    },
  }
}

async function readStaticAgentGoals(read: JournalReadResult, env: ServeAppEnvironment): Promise<Readonly<Record<string, string>> | undefined> {
  const scriptPath = read.opened?.scriptPath
  if (scriptPath === undefined || scriptPath === "") return undefined
  try {
    const script = parseCompatibleWorkflowScriptSource(await env.workflowScriptSourceStore.read(scriptPath))
    return extractStaticAgentGoals(script.source)
  } catch {
    return undefined
  }
}

export function parseServeCliCommand(request: Proven<CliRequest>): Proven<ServeCommandRequest> {
  return parseServeCliRequest(request)
}

export async function runResumeCommandApp(request: Proven<ResumeCommandRequest>, env: WorkflowAppEnvironment): Promise<WorkflowApiResult> {
  const resolved = await readRun(request.runId, env)
  const mutationFiles = await readRunMutationFiles(resolved.runId, env)
  const decision = decideResumeFromJournal({ request, read: resolved.read, databasePath: resolved.databasePath, mutationFiles })
  switch (decision.t) {
    case "completed":
      return decision.result
    case "resume":
      {
        switch (request.background.t) {
          case "launch":
            return launchExistingBackgroundWorkflow({ request, read: resolved.read, databasePath: resolved.databasePath, runId: resolved.runId, env })
          case "foreground":
            break
        }
        const script = parseCompatibleWorkflowScriptSource(await env.workflowScriptSourceStore.read(resolved.read.opened.scriptPath))
        const facts = await env.workflowPreparer.prepare({ script })
        const provider = selectResumeWorkflowProvider({ selection: request.provider, recordedProvider: resolved.read.opened.provider })
        const prepared = prepareWorkflowResumeRun({ read: resolved.read, databasePath: resolved.databasePath, scriptSha256: facts.scriptSha256, provider })
        const journalStore = env.journalStoreFactory.open(prepared)
        try {
          const committedEvents = [...resolved.read.events]
          const attached = await journalStore.commit({
            idempotencyKey: `runner_attached:${prepared.runId}:${env.processPort.pid()}`,
            event: {
              t: "runner_attached",
              pid: env.processPort.pid(),
              mode: "resume",
              cliVersion: CLI_VERSION,
            },
          })
          committedEvents.push(attached.event)
          const heartbeat = await journalStore.heartbeat({ pid: env.processPort.pid() })
          committedEvents.push(heartbeat.event)
          const heartbeatHandle = await startRunnerHeartbeat({ journalStore, env, committedEvents })
          if (prepared.scriptSha256 !== resolved.read.opened.scriptSha256) {
            const changed = await journalStore.commit({
              idempotencyKey: `script_changed:${prepared.runId}:${prepared.scriptSha256}`,
              event: { t: "script_changed", scriptSha256: prepared.scriptSha256 },
            })
            committedEvents.push(changed.event)
          }
          let emittedCount = workflowEventOrdinalSeed(committedEvents)
          const emit = async (event: JournalEventDraft): Promise<void> => {
            emittedCount += 1
            const committed = await journalStore.commit({
              idempotencyKey: `workflow_event:${prepared.runId}:${emittedCount}:${event.t}`,
              event,
            })
            committedEvents.push(committed.event)
          }
          const recordMutationFiles = async (record: JournalMutationRecord): Promise<void> => {
            await journalStore.recordMutationFiles({
              idempotencyKey: mutationIdempotencyKey(prepared.runId, record),
              mutation: record,
            })
          }
          try {
            const outcome = await env.workflowExecutor.execute({ request: resumeAsWorkflowRequest(request, prepared), run: prepared, script, replay: decision.replay, emit, recordMutationFiles })
            await heartbeatHandle.stop()
            const totals = foldJournal({ events: committedEvents, truncatedTail: false }).totals
            const finished = await journalStore.commit({ idempotencyKey: `run_finished:${prepared.runId}`, event: runFinishedEvent({ outcome, totals }) })
            committedEvents.push(finished.event)
            return workflowResult({
              request: resumeAsWorkflowRequest(request, prepared),
              prepared,
              events: committedEvents,
            })
          } catch (error) {
            await heartbeatHandle.stop()
            const finished = await journalStore.commit({
              idempotencyKey: `run_finished:${prepared.runId}`,
              event: failedRunFinishedEvent({
                error: parseErrorMessage(error),
                totals: foldJournal({ events: committedEvents, truncatedTail: false }).totals,
              }),
            })
            committedEvents.push(finished.event)
            return workflowResult({
              request: resumeAsWorkflowRequest(request, prepared),
              prepared,
              events: committedEvents,
            })
          }
        } finally {
          await journalStore.release()
        }
      }
  }
}

export async function runDraftCommandApp(request: Proven<DraftCommandRequest>, env: WorkflowAppEnvironment): Promise<WorkflowApiResult> {
  const cwd = request.cwd === undefined ? env.processPort.cwd() : request.cwd
  const plan = planDraftWorkflow({ request, cwd })
  const script = parseCompatibleWorkflowScriptSource(plan.script)
  await env.draftWorkflowStore.writeDraft(plan)
  return {
    status: "drafted",
    command: "draft",
    workflowName: script.meta.name,
    scriptPath: plan.scriptPath,
    validation: script.compatibility,
    nextSteps: plan.nextSteps,
  }
}

export async function runValidateCommandApp(request: Proven<WorkflowCommandRequest>, env: WorkflowAppEnvironment): Promise<WorkflowApiResult> {
  const scriptPath = await env.workflowScriptLocator.locate(request)
  const script = parseCompatibleWorkflowScriptSource(await env.workflowScriptSourceStore.read(scriptPath))
  return {
    status: "validated",
    command: "validate",
    workflowName: script.meta.name,
    scriptPath,
    compatibility: script.compatibility,
  }
}

export async function runWorkflowCommandApp(request: Proven<WorkflowCommandRequest>, env: WorkflowAppEnvironment): Promise<WorkflowApiResult> {
  const provider = selectWorkflowProvider(request.provider)
  const scriptPath = await env.workflowScriptLocator.locate(request)
  const script = parseCompatibleWorkflowScriptSource(await env.workflowScriptSourceStore.read(scriptPath))
  const facts = await env.workflowPreparer.prepare({ script })
  const prepared = prepareWorkflowRun({ request, provider, scriptPath, script, facts })
  switch (request.background.t) {
    case "launch":
      return launchBackgroundWorkflow({ request, prepared, env })
    case "foreground":
      break
  }
  const journalStore = env.journalStoreFactory.open(prepared)
  try {
    const opened = await journalStore.initializeRun(prepared)
    const committedEvents = [opened.event]
    const attached = await journalStore.commit({
      idempotencyKey: `runner_attached:${prepared.runId}:${env.processPort.pid()}`,
      event: {
        t: "runner_attached",
        pid: env.processPort.pid(),
        mode: runnerAttachMode(prepared.command),
        cliVersion: CLI_VERSION,
      },
    })
    committedEvents.push(attached.event)
    const heartbeat = await journalStore.heartbeat({ pid: env.processPort.pid() })
    committedEvents.push(heartbeat.event)
    const heartbeatHandle = await startRunnerHeartbeat({ journalStore, env, committedEvents })
    let emittedCount = 0
    const emit = async (event: JournalEventDraft): Promise<void> => {
      emittedCount += 1
      const committed = await journalStore.commit({
        idempotencyKey: `workflow_event:${prepared.runId}:${emittedCount}:${event.t}`,
        event,
      })
      committedEvents.push(committed.event)
    }
    const recordMutationFiles = async (record: JournalMutationRecord): Promise<void> => {
      await journalStore.recordMutationFiles({
        idempotencyKey: mutationIdempotencyKey(prepared.runId, record),
        mutation: record,
      })
    }
    try {
      const outcome = await env.workflowExecutor.execute({ request, run: prepared, script, replay: { t: "fresh" }, emit, recordMutationFiles })
      await heartbeatHandle.stop()
      const totals = foldJournal({ events: committedEvents, truncatedTail: false }).totals
      const finished = await journalStore.commit({ idempotencyKey: `run_finished:${prepared.runId}`, event: runFinishedEvent({ outcome, totals }) })
      committedEvents.push(finished.event)
      return workflowResult({
        request,
        prepared,
        events: committedEvents,
      })
    } catch (error) {
      await heartbeatHandle.stop()
      const finished = await journalStore.commit({
        idempotencyKey: `run_finished:${prepared.runId}`,
        event: failedRunFinishedEvent({
          error: parseErrorMessage(error),
          totals: foldJournal({ events: committedEvents, truncatedTail: false }).totals,
        }),
      })
      committedEvents.push(finished.event)
      return workflowResult({
        request,
        prepared,
        events: committedEvents,
      })
    }
  } finally {
    await journalStore.release()
  }
}

async function launchBackgroundWorkflow(input: {
  readonly request: Proven<WorkflowCommandRequest>
  readonly prepared: ReturnType<typeof prepareWorkflowRun>
  readonly env: WorkflowAppEnvironment
}): Promise<Extract<WorkflowApiResult, { readonly status: "async_launched" }>> {
  const journalStore = input.env.journalStoreFactory.open(input.prepared)
  try {
    await journalStore.initializeRun(input.prepared)
  } finally {
    await journalStore.release()
  }
  switch (input.request.background.t) {
    case "foreground":
      throw new Error("background launch policy was not prepared")
    case "launch":
      {
        const status = await launchBackgroundStatusServer({
          mode: input.request.background.statusServer,
          runId: input.prepared.runId,
          env: input.env,
        })
        const launched = await input.env.backgroundLauncher.launchResumeWorker({ runId: input.prepared.runId })
        try {
          for (let poll = 0; poll < input.request.background.handshakeMaxPolls; poll += 1) {
            await input.env.backgroundLauncher.wait({ ms: input.request.background.handshakePollMs })
            const read = parseJournalText(await input.env.journalReader.readText(input.prepared.runId))
            if (hasRunnerAttached({ read, pid: launched.pid })) {
              return {
                status: "async_launched",
                command: input.request.command,
                workflowName: input.prepared.workflowName,
                pid: launched.pid,
                runId: input.prepared.runId,
                databasePath: input.prepared.databasePath,
                scriptPath: input.prepared.scriptPath,
                ...(status.t === "enabled" ? { statusUrl: status.url, statusServerPid: status.pid } : {}),
              }
            }
          }
          throw new Error("background worker did not attach before handshake timeout")
        } catch (error) {
          await terminateBackgroundProcesses({ env: input.env, status, workerPid: launched.pid })
          throw error
        }
      }
  }
}

async function launchExistingBackgroundWorkflow(input: {
  readonly request: Proven<ResumeCommandRequest>
  readonly read: Proven<JournalReadResult>
  readonly databasePath: string
  readonly runId: string
  readonly env: WorkflowAppEnvironment
}): Promise<Extract<WorkflowApiResult, { readonly status: "async_launched" }>> {
  switch (input.request.provider.t) {
    case "explicit":
      if (input.request.provider.provider !== input.read.opened.provider) {
        throw new Error("background resume with a provider override requires a committed launch plan")
      }
      break
    case "default_for_command":
      break
  }
  switch (input.request.background.t) {
    case "foreground":
      throw new Error("background resume policy was not prepared")
    case "launch":
      {
        const status = await launchBackgroundStatusServer({
          mode: input.request.background.statusServer,
          runId: input.runId,
          env: input.env,
        })
        const launched = await input.env.backgroundLauncher.launchResumeWorker({ runId: input.runId })
        try {
          for (let poll = 0; poll < input.request.background.handshakeMaxPolls; poll += 1) {
            await input.env.backgroundLauncher.wait({ ms: input.request.background.handshakePollMs })
            const read = parseJournalText(await input.env.journalReader.readText(input.runId))
            if (hasRunnerAttached({ read, pid: launched.pid })) {
              return {
                status: "async_launched",
                command: input.request.command,
                workflowName: input.read.opened.workflowName,
                pid: launched.pid,
                runId: input.read.opened.runId,
                databasePath: input.databasePath,
                scriptPath: input.read.opened.scriptPath,
                ...(status.t === "enabled" ? { statusUrl: status.url, statusServerPid: status.pid } : {}),
              }
            }
          }
          throw new Error("background worker did not attach before handshake timeout")
        } catch (error) {
          await terminateBackgroundProcesses({ env: input.env, status, workerPid: launched.pid })
          throw error
        }
      }
  }
}

type BackgroundStatusResult =
  | { readonly t: "disabled" }
  | { readonly t: "enabled"; readonly url: string; readonly pid: number }

async function launchBackgroundStatusServer(input: {
  readonly mode: BackgroundStatusServerMode
  readonly runId: string
  readonly env: WorkflowAppEnvironment
}): Promise<BackgroundStatusResult> {
  switch (input.mode.t) {
    case "disabled":
      return { t: "disabled" }
    case "enabled":
      {
        await input.env.serveSessionStore.removeSession(input.runId)
        const launched = await input.env.backgroundLauncher.launchStatusServer({
          runId: input.runId,
          host: input.mode.host,
          port: input.mode.port,
        })
        for (let poll = 0; poll < input.mode.sessionMaxPolls; poll += 1) {
          await input.env.backgroundLauncher.wait({ ms: input.mode.sessionPollMs })
          try {
            const record = parseServeSessionText(await input.env.serveSessionStore.readSession(input.runId))
            return { t: "enabled", url: record.url, pid: record.pid }
          } catch {
          }
        }
        await input.env.backgroundLauncher.terminate({ pid: launched.pid })
        throw new Error(`status server pid ${launched.pid} did not publish a serve session before handshake timeout`)
      }
  }
}

async function terminateBackgroundProcesses(input: {
  readonly env: WorkflowAppEnvironment
  readonly status: BackgroundStatusResult
  readonly workerPid: number
}): Promise<void> {
  await input.env.backgroundLauncher.terminate({ pid: input.workerPid })
  switch (input.status.t) {
    case "disabled":
      return
    case "enabled":
      await input.env.backgroundLauncher.terminate({ pid: input.status.pid })
  }
}

function runFinishedEvent(input: {
  readonly outcome: WorkflowExecutionOutcome
  readonly totals: { readonly totalTokens: number; readonly totalToolCalls: number }
}): Extract<JournalEventDraft, { readonly t: "run_finished" }> {
  switch (input.outcome.status) {
    case "done":
      return {
        t: "run_finished",
        status: "done",
        result: input.outcome.result,
        totalTokens: input.totals.totalTokens,
        totalToolCalls: input.totals.totalToolCalls,
        durationMs: 0,
      }
    case "failed":
      return failedRunFinishedEvent({ error: input.outcome.error, totals: input.totals })
  }
}

function failedRunFinishedEvent(input: {
  readonly error: string
  readonly totals: { readonly totalTokens: number; readonly totalToolCalls: number }
}): Extract<JournalEventDraft, { readonly t: "run_finished" }> {
  return {
    t: "run_finished",
    status: "failed",
    error: input.error,
    totalTokens: input.totals.totalTokens,
    totalToolCalls: input.totals.totalToolCalls,
    durationMs: 0,
  }
}

export async function runJournalQueryApp(request: Proven<JournalQueryRequest>, env: JournalQueryEnvironment): Promise<WorkflowApiResult> {
  const resolved = await readRun(request.runId, env)
  const read = resolved.read
  const state = foldJournal(read)
  if (request.command === "inspect") {
    return { status: "inspected", snapshot: toWorkflowSnapshot({ state, databasePath: resolved.databasePath }) }
  }
  return {
    status: "summarized",
    summary: toWorkflowStatusSummary({ state, databasePath: resolved.databasePath, tailEvents: read.events, eventLimit: request.eventLimit }),
  }
}

export async function runJournalListApp(request: Proven<JournalListRequest>, env: WorkflowAppEnvironment): Promise<WorkflowApiResult> {
  const candidates = await listRuns(env)
  const entries: WorkflowListEntry[] = []
  for (const candidate of candidates) {
    try {
      const resolved = await readRun(candidate.runId, env)
      const read = resolved.read
      const state = foldJournal(read)
      entries.push({
        ...toWorkflowStatusSummary({ state, databasePath: resolved.databasePath, tailEvents: read.events, eventLimit: request.eventLimit }),
        updatedAt: candidate.updatedAt,
      })
    } catch (error) {
      entries.push({ runId: candidate.runId, databasePath: candidate.databasePath, updatedAt: candidate.updatedAt, error: parseErrorMessage(error) })
    }
  }
  entries.sort((a, b) => b.updatedAt.localeCompare(a.updatedAt))
  return { status: "listed", workflows: entries.slice(0, request.limit) }
}

async function listRuns(env: WorkflowAppEnvironment): Promise<readonly JournalRunCandidate[]> {
  try {
    return await env.journalDirectory.listRuns()
  } catch (error) {
    const facts = parseNodeErrorFacts(error)
    switch (facts.t) {
      case "coded":
        if (facts.code === "ENOENT") return []
        throw error
      case "uncoded":
        throw error
    }
  }
}

export async function readRun(runId: string, env: JournalQueryEnvironment): Promise<{ readonly runId: string; readonly databasePath: string; readonly read: Proven<JournalReadResult> }> {
  const resolved = await env.journalReader.resolveRun({ runId })
  const text = await env.journalReader.readText(resolved.runId)
  return { ...resolved, read: parseJournalText(text) }
}

async function readRunMutationFiles(runId: string, env: WorkflowAppEnvironment): Promise<readonly string[]> {
  try {
    return parseJournalMutationText(await env.journalReader.readMutationText(runId))
  } catch (error) {
    const facts = parseNodeErrorFacts(error)
    switch (facts.t) {
      case "coded":
        if (facts.code === "ENOENT") return []
        throw error
      case "uncoded":
        throw error
    }
  }
}

async function startRunnerHeartbeat(input: {
  readonly journalStore: JournalStore
  readonly env: WorkflowAppEnvironment
  readonly committedEvents: JournalReadResult["events"][number][]
}): Promise<{ readonly stop: () => Promise<void> }> {
  return input.env.runnerHeartbeat.start({
    writeHeartbeat: async () => {
      const heartbeat = await input.journalStore.heartbeat({ pid: input.env.processPort.pid() })
      input.committedEvents.push(heartbeat.event)
    },
  })
}

function mutationIdempotencyKey(runId: string, record: JournalMutationRecord): string {
  return `mutation:${runId}:${record.node}:${record.attempt}:${JSON.stringify(record.files)}`
}

function workflowResult(input: {
  readonly request: WorkflowCommandRequest
  readonly prepared: ReturnType<typeof prepareWorkflowRun>
  readonly events: readonly JournalReadResult["events"][number][]
}): WorkflowApiResult {
  const state = foldJournal({ events: input.events, truncatedTail: false })
  return {
    status: "completed",
    command: input.request.command,
    snapshot: toWorkflowSnapshot({ state, databasePath: input.prepared.databasePath }),
    budgetPlan: input.prepared.budgetPlan,
    databasePath: input.prepared.databasePath,
    scriptPath: input.prepared.scriptPath,
  }
}

function workflowEventOrdinalSeed(events: readonly JournalReadResult["events"][number][]): number {
  let count = 0
  for (const event of events) {
    switch (event.t) {
      case "phase_entered":
      case "log_emitted":
      case "agent_scheduled":
      case "agent_started":
      case "agent_progress":
      case "agent_completed":
      case "agent_failed":
      case "agent_retried":
      case "agent_replayed":
      case "child_started":
      case "child_finished":
      case "script_changed":
        count += 1
        break
      case "run_opened":
      case "runner_attached":
      case "runner_heartbeat":
      case "runner_detached":
      case "run_finished":
        break
    }
  }
  return count
}

function resumeAsWorkflowRequest(request: Proven<ResumeCommandRequest>, prepared: ReturnType<typeof prepareWorkflowResumeRun>): WorkflowCommandRequest {
  return {
    command: "resume",
    script: { t: "unresolved", value: prepared.scriptPath },
    args: prepared.args,
    provider: { t: "explicit", provider: prepared.provider },
    approval: request.approval,
    requestedRunId: prepared.requestedRunId,
    noInput: request.noInput,
    quiet: request.quiet,
    background: { t: "foreground" },
    backgroundWorker: false,
    options: {
      budget: request.options.budget,
      workingDirectory: request.options.workingDirectory,
      defaultModel: request.options.defaultModel,
      modelPolicy: request.options.modelPolicy,
      codexBaseUrl: request.options.codexBaseUrl,
      codexPathOverride: request.options.codexPathOverride,
      codexConfig: request.options.codexConfig,
      skipGitRepoCheck: request.options.skipGitRepoCheck,
      deterministicTimestamps: request.options.deterministicTimestamps,
      echoPrompts: request.options.echoPrompts,
      workflowPermissionKey: request.options.workflowPermissionKey,
      turnBudget: request.options.turnBudget,
      limits: prepared.limits,
    },
  }
}
