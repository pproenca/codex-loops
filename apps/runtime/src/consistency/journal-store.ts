import type { CommittedJournalEvent, JournalCommitRequest, JournalEvent, JournalEventDraft, JournalMutationRecord, PreparedWorkflowRun } from "../domain/contracts.ts"
import type { JournalStore, JournalStoreFactory } from "../ports/index.ts"

export class JournalCommitConflict extends Error {
  constructor(message: string) {
    super(message)
    this.name = "JournalCommitConflict"
  }
}

export class InMemoryJournalStore implements JournalStore {
  readonly #events: CommittedJournalEvent[] = []
  readonly #byIdempotencyKey = new Map<string, CommittedJournalEvent>()
  readonly #draftByIdempotencyKey = new Map<string, JournalEventDraft>()
  readonly #mutationByIdempotencyKey = new Map<string, JournalMutationRecord>()
  #writeQueue: Promise<void> = Promise.resolve()
  #nextSeq = 1
  #runOpenedCommitted = false
  #terminalCommitted = false

  async commit(request: JournalCommitRequest): Promise<CommittedJournalEvent> {
    return this.#enqueue(() => this.#commitUnlocked(request))
  }

  #commitUnlocked(request: JournalCommitRequest): CommittedJournalEvent {
    const event = draftForCommit(request.event)
    const existing = this.#byIdempotencyKey.get(request.idempotencyKey)
    if (existing !== undefined) {
      const existingDraft = this.#draftByIdempotencyKey.get(request.idempotencyKey)
      if (JSON.stringify(existingDraft) !== JSON.stringify(event)) {
        throw new JournalCommitConflict("journal idempotency key reused for a different event")
      }
      return existing
    }
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
    this.#nextSeq = seq + 1
    this.#events.push(committed)
    this.#byIdempotencyKey.set(request.idempotencyKey, committed)
    this.#draftByIdempotencyKey.set(request.idempotencyKey, event)
    if (event.t === "run_opened") this.#runOpenedCommitted = true
    if (event.t === "run_finished") this.#terminalCommitted = true
    return committed
  }

  async initializeRun(run: PreparedWorkflowRun): Promise<CommittedJournalEvent> {
    return this.commit({
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
  }

  async heartbeat(input: { readonly pid: number }): Promise<CommittedJournalEvent> {
    return this.#enqueue(() => this.#commitUnlocked({
      idempotencyKey: `runner_heartbeat:${this.#nextSeq}:${input.pid}`,
      event: { t: "runner_heartbeat", pid: input.pid },
    }))
  }

  async recordMutationFiles(input: { readonly idempotencyKey: string; readonly mutation: JournalMutationRecord }): Promise<void> {
    return this.#enqueue(async () => {
      const existing = this.#mutationByIdempotencyKey.get(input.idempotencyKey)
      if (existing !== undefined) {
        if (JSON.stringify(existing) !== JSON.stringify(input.mutation)) {
          throw new JournalCommitConflict("journal mutation idempotency key reused for a different record")
        }
        return
      }
      this.#mutationByIdempotencyKey.set(input.idempotencyKey, input.mutation)
    })
  }

  snapshot(): readonly CommittedJournalEvent[] {
    return this.#events
  }

  async release(): Promise<void> {
    await this.#writeQueue
  }

  #enqueue<T>(operation: () => T | Promise<T>): Promise<T> {
    const run = this.#writeQueue.then(operation, operation)
    this.#writeQueue = run.then(() => undefined, () => undefined)
    return run
  }
}

export class InMemoryJournalStoreFactory implements JournalStoreFactory {
  open(): JournalStore {
    return new InMemoryJournalStore()
  }
}

export function draftForCommit(event: JournalEventDraft): JournalEventDraft {
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
        totalTokens: event.totalTokens,
        totalToolCalls: event.totalToolCalls,
        durationMs: event.durationMs,
        ...(event.result === undefined ? {} : { result: event.result }),
        ...(event.error === undefined ? {} : { error: event.error }),
      }
  }
}

export function commitEvent(seq: number, event: JournalEventDraft): JournalEvent {
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
