import { randomUUID } from "node:crypto"
import { mkdir, open, readFile, rename, rm, stat } from "node:fs/promises"
import { dirname } from "node:path"

import type { CommittedJournalEvent, JournalCommitRequest, JournalEvent, JournalEventDraft, JournalMutationRecord, PreparedWorkflowRun } from "../domain/contracts.ts"
import type { JournalStore, JournalStoreFactory, ProcessPort } from "../ports/index.ts"
import { parseJournalText } from "../trust/journal-event.ts"
import { parseJournalLockText } from "../trust/journal-lock.ts"
import { parseNodeErrorFacts } from "../trust/node-error.ts"
import { JournalCommitConflict, draftForCommit } from "./journal-store.ts"

export class FileJournalStoreFactory implements JournalStoreFactory {
  readonly #process: ProcessPort

  constructor(process: ProcessPort) {
    this.#process = process
  }

  open(run: PreparedWorkflowRun): JournalStore {
    return new FileJournalStore(run.journalPath, this.#process)
  }
}

export class FileJournalStore implements JournalStore {
  readonly #path: string
  readonly #lockPath: string
  readonly #process: ProcessPort
  readonly #events: CommittedJournalEvent[] = []
  readonly #byIdempotencyKey = new Map<string, CommittedJournalEvent>()
  readonly #draftByIdempotencyKey = new Map<string, JournalEventDraft>()
  readonly #mutationByIdempotencyKey = new Map<string, JournalMutationRecord>()
  #writeQueue: Promise<void> = Promise.resolve()
  #nextSeq = 1
  #runOpenedCommitted = false
  #terminalCommitted = false
  #opened = false
  #locked = false
  #recoveredWorkflowEventCount = 0

  constructor(path: string, process: ProcessPort) {
    this.#path = path
    this.#lockPath = `${path}.lock`
    this.#process = process
  }

  async commit(request: JournalCommitRequest): Promise<CommittedJournalEvent> {
    return this.#enqueue(async () => {
      await this.#openForWrite()
      return this.#commitUnlocked(request)
    })
  }

  async #commitUnlocked(request: JournalCommitRequest): Promise<CommittedJournalEvent> {
    const existing = this.#byIdempotencyKey.get(request.idempotencyKey)
    if (existing !== undefined) {
      const existingDraft = this.#draftByIdempotencyKey.get(request.idempotencyKey)
      if (JSON.stringify(existingDraft) !== JSON.stringify(draftForCommit(request.event))) {
        throw new JournalCommitConflict("journal idempotency key reused for a different event")
      }
      return existing
    }
    const event = draftForCommit(request.event)
    if (event.t !== "run_opened" && !this.#runOpenedCommitted) {
      throw new JournalCommitConflict("journal must open the run before other events")
    }
    if (event.t === "run_opened" && (this.#runOpenedCommitted || this.#events.length > 0)) {
      throw new JournalCommitConflict("journal already has a run_opened event")
    }
    if (this.#terminalCommitted) {
      throw new JournalCommitConflict("journal already has a terminal run event")
    }
    const seq = this.#nextSeq
    const committed = { seq, event: commitEvent(seq, event) }
    await appendDurably(this.#path, committed.event)
    this.#nextSeq = seq + 1
    this.#events.push(committed)
    this.#byIdempotencyKey.set(request.idempotencyKey, committed)
    this.#draftByIdempotencyKey.set(request.idempotencyKey, event)
    if (event.t === "run_opened") this.#runOpenedCommitted = true
    if (event.t === "run_finished") this.#terminalCommitted = true
    return committed
  }

  async initializeRun(run: PreparedWorkflowRun): Promise<CommittedJournalEvent> {
    return this.#enqueue(async () => {
      await this.#openForWrite()
      if (run.journalPath !== this.#path) {
        throw new JournalCommitConflict("prepared run journal path does not match the opened file journal")
      }
      const committed = await this.#commitUnlocked({
        idempotencyKey: `run_opened:${run.runId}`,
        event: {
          t: "run_opened",
          schema: "agent-loops/journal@2",
          runId: run.runId,
          workflowName: run.workflowName,
          scriptPath: run.scriptPath,
          scriptSha256: run.scriptSha256,
          args: run.args,
          provider: run.provider,
          budgetPlan: run.budgetPlan,
          limits: run.limits,
          runtimeContract: run.runtimeContract,
        },
      })
      if (run.pointerPath !== undefined && run.pointerTarget !== undefined) {
        await writePointerDurably(run.pointerPath, run.pointerTarget)
      }
      return committed
    })
  }

  async heartbeat(input: { readonly pid: number }): Promise<CommittedJournalEvent> {
    return this.#enqueue(async () => {
      await this.#openForWrite()
      return this.#commitUnlocked({
        idempotencyKey: `runner_heartbeat:${this.#nextSeq}:${input.pid}`,
        event: { t: "runner_heartbeat", pid: input.pid },
      })
    })
  }

  async recordMutationFiles(input: { readonly idempotencyKey: string; readonly mutation: JournalMutationRecord }): Promise<void> {
    return this.#enqueue(async () => {
      await this.#openForWrite()
      const existing = this.#mutationByIdempotencyKey.get(input.idempotencyKey)
      if (existing !== undefined) {
        if (JSON.stringify(existing) !== JSON.stringify(input.mutation)) {
          throw new JournalCommitConflict("journal mutation idempotency key reused for a different record")
        }
        return
      }
      await appendMutationDurably(`${this.#path}.mutations.jsonl`, input.mutation)
      this.#mutationByIdempotencyKey.set(input.idempotencyKey, input.mutation)
    })
  }

  snapshot(): readonly CommittedJournalEvent[] {
    return this.#events
  }

  async release(): Promise<void> {
    await this.#enqueue(async () => {
      if (!this.#locked) return
      const lock = await readTextIfPresent(this.#lockPath)
      if (lock.t === "present") {
        const facts = parseJournalLockText(lock.text)
        if (facts.t === "pid" && facts.pid === this.#process.pid()) {
          await rm(this.#lockPath, { force: true })
        }
      }
      this.#locked = false
    })
  }

  async #openForWrite(): Promise<void> {
    if (this.#opened) return
    await acquireLock({ lockPath: this.#lockPath, journalPath: this.#path, process: this.#process })
    this.#locked = true
    await this.#recoverExistingEvents()
    this.#opened = true
  }

  async #recoverExistingEvents(): Promise<void> {
    const text = await readTextIfPresent(this.#path)
    if (text.t === "missing") return
    const read = parseJournalText(text.text)
    if (read.truncatedTail) throw new JournalCommitConflict("journal has a truncated tail")
    for (const event of read.events) this.#recoverEvent(event)
  }

  #recoverEvent(event: JournalEvent): void {
    const committed = { seq: event.seq, event }
    this.#events.push(committed)
    if (event.seq >= this.#nextSeq) this.#nextSeq = event.seq + 1
    switch (event.t) {
      case "run_opened":
        this.#runOpenedCommitted = true
        this.#rememberCommitted(`run_opened:${event.runId}`, committed, draftFromCommitted(event))
        return
      case "run_finished":
        this.#terminalCommitted = true
        this.#rememberCommitted(`run_finished:${this.#runId()}`, committed, draftFromCommitted(event))
        return
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
        this.#recoveredWorkflowEventCount += 1
        this.#rememberCommitted(workflowEventIdempotencyKey(this.#runId(), this.#recoveredWorkflowEventCount, event), committed, draftFromCommitted(event))
        return
      case "script_changed":
        this.#recoveredWorkflowEventCount += 1
        this.#rememberCommitted(`script_changed:${this.#runId()}:${event.scriptSha256}`, committed, draftFromCommitted(event))
        return
      case "runner_attached":
        this.#rememberCommitted(`runner_attached:${this.#runId()}:${event.pid}`, committed, draftFromCommitted(event))
        return
      case "runner_heartbeat":
      case "runner_detached":
        return
    }
  }

  #rememberCommitted(idempotencyKey: string, committed: CommittedJournalEvent, event: JournalEventDraft): void {
    this.#byIdempotencyKey.set(idempotencyKey, committed)
    this.#draftByIdempotencyKey.set(idempotencyKey, draftForCommit(event))
  }

  #runId(): string {
    const opened = this.#events.find((entry) => entry.event.t === "run_opened")
    if (opened?.event.t === "run_opened") return opened.event.runId
    throw new JournalCommitConflict("journal recovered terminal event before run_opened")
  }

  #enqueue<T>(operation: () => T | Promise<T>): Promise<T> {
    const run = this.#writeQueue.then(operation, operation)
    this.#writeQueue = run.then(() => undefined, () => undefined)
    return run
  }
}

function workflowEventIdempotencyKey(runId: string, ordinal: number, event: Extract<JournalEvent, { readonly t: JournalEventDraft["t"] }>): string {
  return `workflow_event:${runId}:${ordinal}:${event.t}`
}

function draftFromCommitted(event: JournalEvent): JournalEventDraft {
  switch (event.t) {
    case "run_opened":
      return {
        t: event.t,
        schema: event.schema,
        runId: event.runId,
        workflowName: event.workflowName,
        scriptPath: event.scriptPath,
        scriptSha256: event.scriptSha256,
        args: event.args,
        provider: event.provider,
        budgetPlan: event.budgetPlan,
        limits: event.limits,
        runtimeContract: event.runtimeContract,
      }
    case "runner_attached":
      return {
        t: event.t,
        pid: event.pid,
        mode: event.mode,
        cliVersion: event.cliVersion,
        ...(event.startedAt === undefined ? {} : { startedAt: event.startedAt }),
      }
    case "runner_heartbeat":
      return { t: event.t, pid: event.pid }
    case "phase_entered":
      return { t: event.t, phase: event.phase, title: event.title, ...(event.w === undefined ? {} : { w: event.w }) }
    case "log_emitted":
      return { t: event.t, message: event.message, ...(event.w === undefined ? {} : { w: event.w }) }
    case "agent_scheduled":
      return {
        t: event.t,
        node: event.node,
        label: event.label,
        attempt: event.attempt,
        promptHash: event.promptHash,
        optionsHash: event.optionsHash,
        promptPreview: event.promptPreview,
        ...(event.promptFull === undefined ? {} : { promptFull: event.promptFull }),
        effort: event.effort,
        ...(event.phase === undefined ? {} : { phase: event.phase }),
        ...(event.phaseTitle === undefined ? {} : { phaseTitle: event.phaseTitle }),
        ...(event.schemaHash === undefined ? {} : { schemaHash: event.schemaHash }),
        ...(event.model === undefined ? {} : { model: event.model }),
        ...(event.routeReason === undefined ? {} : { routeReason: event.routeReason }),
        ...(event.agentType === undefined ? {} : { agentType: event.agentType }),
        ...(event.agentDefinitionSha === undefined ? {} : { agentDefinitionSha: event.agentDefinitionSha }),
        ...(event.isolation === undefined ? {} : { isolation: event.isolation }),
        ...(event.risk === undefined ? {} : { risk: event.risk }),
        ...(event.w === undefined ? {} : { w: event.w }),
      }
    case "agent_started":
      return {
        t: event.t,
        node: event.node,
        attempt: event.attempt,
        ...(event.threadId === undefined ? {} : { threadId: event.threadId }),
        ...(event.w === undefined ? {} : { w: event.w }),
      }
    case "agent_progress":
      return {
        t: event.t,
        node: event.node,
        attempt: event.attempt,
        ...(event.tokens === undefined ? {} : { tokens: event.tokens }),
        ...(event.toolCalls === undefined ? {} : { toolCalls: event.toolCalls }),
        ...(event.lastToolName === undefined ? {} : { lastToolName: event.lastToolName }),
        ...(event.lastToolSummary === undefined ? {} : { lastToolSummary: event.lastToolSummary }),
        ...(event.w === undefined ? {} : { w: event.w }),
      }
    case "agent_completed":
      return {
        t: event.t,
        node: event.node,
        attempt: event.attempt,
        result: event.result,
        tokens: event.tokens,
        toolCalls: event.toolCalls,
        durationMs: event.durationMs,
        source: event.source,
        ...(event.threadId === undefined ? {} : { threadId: event.threadId }),
        ...(event.w === undefined ? {} : { w: event.w }),
      }
    case "agent_retried":
      return {
        t: event.t,
        node: event.node,
        attempt: event.attempt,
        reason: event.reason,
        errors: event.errors,
        ...(event.w === undefined ? {} : { w: event.w }),
      }
    case "agent_failed":
      return {
        t: event.t,
        node: event.node,
        attempt: event.attempt,
        error: event.error,
        ...(event.tokens === undefined ? {} : { tokens: event.tokens }),
        ...(event.toolCalls === undefined ? {} : { toolCalls: event.toolCalls }),
        ...(event.durationMs === undefined ? {} : { durationMs: event.durationMs }),
        ...(event.w === undefined ? {} : { w: event.w }),
      }
    case "agent_replayed":
      return {
        t: event.t,
        node: event.node,
        attempt: event.attempt,
        ...(event.w === undefined ? {} : { w: event.w }),
      }
    case "child_started":
      return { t: event.t, w: event.w, name: event.name }
    case "child_finished":
      return {
        t: event.t,
        w: event.w,
        status: event.status,
        ...(event.result === undefined ? {} : { result: event.result }),
      }
    case "script_changed":
      return { t: event.t, scriptSha256: event.scriptSha256 }
    case "run_finished":
      return {
        t: event.t,
        status: event.status,
        result: event.result,
        error: event.error,
        totalTokens: event.totalTokens,
        totalToolCalls: event.totalToolCalls,
        durationMs: event.durationMs,
      }
    case "runner_detached":
      throw new JournalCommitConflict("only write-authority drafts can be recovered for idempotency")
  }
}

const LOCK_FRESH_GRACE_MS = 2_000
const HEARTBEAT_STALE_MS = 30_000

async function acquireLock(input: {
  readonly lockPath: string
  readonly journalPath: string
  readonly process: ProcessPort
}): Promise<void> {
  await mkdir(dirname(input.lockPath), { recursive: true })
  const created = await tryCreateLock(input.lockPath, input.process.pid())
  if (created) return
  const current = await readTextIfPresent(input.lockPath)
  if (current.t === "missing") {
    const retried = await tryCreateLock(input.lockPath, input.process.pid())
    if (retried) return
    throw new JournalCommitConflict(`journal lock contention: ${input.lockPath}`)
  }
  const facts = parseJournalLockText(current.text)
  if (facts.t === "malformed") throw new JournalCommitConflict(`journal lock contention: ${input.lockPath}`)
  if (processOwnsLivePid(input.process, facts.pid)) {
    if (await lockIsFresh(input.lockPath)) throw new JournalCommitConflict(`journal lock contention: ${input.lockPath}`)
    if (await journalHasFreshHeartbeat({ journalPath: input.journalPath, pid: facts.pid })) {
      throw new JournalCommitConflict(`journal is locked by live runner pid ${facts.pid}: ${input.lockPath}`)
    }
  }
  await rm(input.lockPath, { force: true })
  const taken = await tryCreateLock(input.lockPath, input.process.pid())
  if (!taken) throw new JournalCommitConflict(`journal lock contention: ${input.lockPath}`)
}

async function lockIsFresh(lockPath: string): Promise<boolean> {
  const facts = await stat(lockPath)
  return Date.now() - facts.mtimeMs < LOCK_FRESH_GRACE_MS
}

async function journalHasFreshHeartbeat(input: { readonly journalPath: string; readonly pid: number }): Promise<boolean> {
  const text = await readTextIfPresent(input.journalPath)
  if (text.t === "missing") return false
  const read = parseJournalText(text.text)
  let lastHeartbeatMs: number | undefined
  for (const event of read.events) {
    if (event.t === "runner_heartbeat" && event.pid === input.pid && event.ts !== undefined) {
      const parsed = Date.parse(event.ts)
      if (Number.isFinite(parsed)) lastHeartbeatMs = parsed
    }
  }
  if (lastHeartbeatMs === undefined) return false
  return Date.now() - lastHeartbeatMs < HEARTBEAT_STALE_MS
}

function processOwnsLivePid(process: ProcessPort, pid: number): boolean {
  try {
    process.probePid(pid)
    return true
  } catch (error) {
    const facts = parseNodeErrorFacts(error)
    switch (facts.t) {
      case "coded":
        return facts.code === "EPERM"
      case "uncoded":
        return false
    }
  }
}

async function tryCreateLock(lockPath: string, pid: number): Promise<boolean> {
  try {
    const handle = await open(lockPath, "wx")
    try {
      await handle.writeFile(`${pid}\n`, "utf8")
      await handle.sync()
    } finally {
      await handle.close()
    }
    return true
  } catch (error) {
    const facts = parseNodeErrorFacts(error)
    if (facts.t === "coded" && facts.code === "EEXIST") return false
    throw error
  }
}

async function readTextIfPresent(path: string): Promise<{ readonly t: "present"; readonly text: string } | { readonly t: "missing" }> {
  try {
    return { t: "present", text: await readFile(path, "utf8") }
  } catch (error) {
    const facts = parseNodeErrorFacts(error)
    if (facts.t === "coded" && facts.code === "ENOENT") return { t: "missing" }
    throw error
  }
}

async function appendDurably(path: string, event: JournalEvent): Promise<void> {
  await mkdir(dirname(path), { recursive: true })
  const handle = await open(path, "a")
  try {
    await handle.appendFile(`${JSON.stringify(event)}\n`, "utf8")
    await handle.sync()
  } finally {
    await handle.close()
  }
}

async function appendMutationDurably(path: string, mutation: JournalMutationRecord): Promise<void> {
  await mkdir(dirname(path), { recursive: true })
  const handle = await open(path, "a")
  try {
    await handle.appendFile(`${JSON.stringify(mutation)}\n`, "utf8")
    await handle.sync()
  } finally {
    await handle.close()
  }
}

async function writePointerDurably(pointerPath: string, target: string): Promise<void> {
  await mkdir(dirname(pointerPath), { recursive: true })
  const tempPath = `${pointerPath}.${randomUUID()}.tmp`
  const handle = await open(tempPath, "w")
  try {
    await handle.writeFile(`${JSON.stringify({ $pointer: target })}\n`, "utf8")
    await handle.sync()
  } finally {
    await handle.close()
  }
  await rename(tempPath, pointerPath)
  await syncDirectory(dirname(pointerPath))
}

async function syncDirectory(path: string): Promise<void> {
  const handle = await open(path, "r")
  try {
    await handle.sync()
  } finally {
    await handle.close()
  }
}

function commitEvent(seq: number, event: JournalEventDraft): JournalEvent {
  switch (event.t) {
    case "run_opened":
      return { seq, ...event }
    case "runner_attached":
      return {
        seq,
        t: event.t,
        pid: event.pid,
        mode: event.mode,
        cliVersion: event.cliVersion,
        ...(event.startedAt === undefined ? {} : { startedAt: event.startedAt }),
      }
    case "runner_heartbeat":
      return { seq, t: event.t, pid: event.pid, ts: new Date().toISOString() }
    case "phase_entered":
      return { seq, ...event }
    case "log_emitted":
      return { seq, ...event }
    case "agent_scheduled":
      return { seq, ...event }
    case "agent_started":
      return { seq, ...event }
    case "agent_progress":
      return { seq, ...event }
    case "agent_completed":
      return { seq, ...event }
    case "agent_retried":
      return { seq, ...event }
    case "agent_failed":
      return { seq, ...event }
    case "agent_replayed":
      return { seq, ...event }
    case "child_started":
      return { seq, ...event }
    case "child_finished":
      return { seq, ...event }
    case "script_changed":
      return { seq, ...event }
    case "run_finished":
      return { seq, ...event }
  }
}
