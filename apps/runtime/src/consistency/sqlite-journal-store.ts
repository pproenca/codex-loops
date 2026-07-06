import { mkdir } from "node:fs/promises"
import { dirname } from "node:path"
import { DatabaseSync } from "node:sqlite"

import type { CommittedJournalEvent, JournalCommitRequest, JournalEvent, JournalEventDraft, JournalMutationRecord, PreparedWorkflowRun } from "../domain/contracts.ts"
import type { JournalStore, JournalStoreFactory, ProcessPort } from "../ports/index.ts"
import { parseJournalEventLine } from "../trust/journal-event.ts"
import { parseNodeErrorFacts } from "../trust/node-error.ts"
import { JournalCommitConflict, commitEvent, draftForCommit } from "./journal-store.ts"

export class SqliteJournalStoreFactory implements JournalStoreFactory {
  readonly #databasePath: string
  readonly #process: ProcessPort

  constructor(databasePath: string, process: ProcessPort) {
    this.#databasePath = databasePath
    this.#process = process
  }

  open(run: PreparedWorkflowRun): JournalStore {
    if (run.databasePath !== this.#databasePath) {
      throw new JournalCommitConflict("prepared run database path does not match the sqlite journal store")
    }
    return new SqliteJournalStore(this.#databasePath, run.runId, this.#process)
  }
}

export class SqliteJournalStore implements JournalStore {
  readonly #databasePath: string
  readonly #runId: string
  readonly #process: ProcessPort
  readonly #events: CommittedJournalEvent[] = []
  readonly #byIdempotencyKey = new Map<string, CommittedJournalEvent>()
  readonly #draftJsonByIdempotencyKey = new Map<string, string>()
  readonly #mutationJsonByIdempotencyKey = new Map<string, string>()
  #writeQueue: Promise<void> = Promise.resolve()
  #nextSeq = 1
  #runOpenedCommitted = false
  #terminalCommitted = false
  #opened = false
  #locked = false
  #db: DatabaseSync | undefined

  constructor(databasePath: string, runId: string, process: ProcessPort) {
    this.#databasePath = databasePath
    this.#runId = runId
    this.#process = process
  }

  async commit(request: JournalCommitRequest): Promise<CommittedJournalEvent> {
    return this.#enqueue(async () => {
      await this.#openForWrite()
      return this.#commitUnlocked(request)
    })
  }

  async initializeRun(run: PreparedWorkflowRun): Promise<CommittedJournalEvent> {
    return this.#enqueue(async () => {
      await this.#openForWrite()
      if (run.runId !== this.#runId) throw new JournalCommitConflict("prepared run id does not match the opened sqlite journal")
      if (run.databasePath !== this.#databasePath) throw new JournalCommitConflict("prepared run database path does not match the opened sqlite journal")
      const committed = this.#commitUnlocked({
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
      this.#dbOrThrow().prepare("insert or replace into metadata(key, value) values('latest_run_id', ?)").run(run.runId)
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
      const mutationJson = JSON.stringify(input.mutation)
      const existing = this.#mutationJsonByIdempotencyKey.get(input.idempotencyKey)
      if (existing !== undefined) {
        if (existing !== mutationJson) throw new JournalCommitConflict("journal mutation idempotency key reused for a different record")
        return
      }
      this.#dbOrThrow()
        .prepare("insert into mutations(run_id, idempotency_key, mutation_json, created_at) values(?, ?, ?, ?)")
        .run(this.#runId, input.idempotencyKey, mutationJson, new Date().toISOString())
      this.#mutationJsonByIdempotencyKey.set(input.idempotencyKey, mutationJson)
    })
  }

  async release(): Promise<void> {
    await this.#enqueue(() => {
      if (!this.#locked) {
        this.#close()
        return
      }
      this.#dbOrThrow().prepare("delete from run_locks where run_id = ? and pid = ?").run(this.#runId, this.#process.pid())
      this.#locked = false
      this.#close()
    })
  }

  async #openForWrite(): Promise<void> {
    if (this.#opened) return
    await mkdir(dirname(this.#databasePath), { recursive: true })
    const db = new DatabaseSync(this.#databasePath, { timeout: 5_000 })
    this.#db = db
    initializeSqliteSchema(db)
    this.#acquireLock()
    this.#locked = true
    this.#recoverExistingRows()
    this.#opened = true
  }

  #commitUnlocked(request: JournalCommitRequest): CommittedJournalEvent {
    const event = draftForCommit(request.event)
    const draftJson = JSON.stringify(event)
    const existing = this.#byIdempotencyKey.get(request.idempotencyKey)
    if (existing !== undefined) {
      if (this.#draftJsonByIdempotencyKey.get(request.idempotencyKey) !== draftJson) {
        throw new JournalCommitConflict("journal idempotency key reused for a different event")
      }
      return existing
    }
    if (event.t !== "run_opened" && !this.#runOpenedCommitted) throw new JournalCommitConflict("journal must open the run before other events")
    if (event.t === "run_opened" && (this.#runOpenedCommitted || this.#events.length > 0)) throw new JournalCommitConflict("journal already has a run_opened event")
    if (this.#terminalCommitted) throw new JournalCommitConflict("journal already has a terminal run event")

    const seq = this.#nextSeq
    const committed = { seq, event: commitEvent(seq, event) }
    const db = this.#dbOrThrow()
    db.exec("begin immediate")
    try {
      db.prepare("insert into events(run_id, seq, event_type, event_json, created_at) values(?, ?, ?, ?, ?)")
        .run(this.#runId, seq, committed.event.t, JSON.stringify(committed.event), new Date().toISOString())
      db.prepare("insert into idempotency_keys(run_id, idempotency_key, seq, draft_json) values(?, ?, ?, ?)")
        .run(this.#runId, request.idempotencyKey, seq, draftJson)
      this.#upsertRunRow(committed.event)
      db.exec("commit")
    } catch (error) {
      db.exec("rollback")
      throw error
    }

    this.#nextSeq = seq + 1
    this.#events.push(committed)
    this.#rememberCommitted(request.idempotencyKey, committed, draftJson)
    if (event.t === "run_opened") this.#runOpenedCommitted = true
    if (event.t === "run_finished") this.#terminalCommitted = true
    return committed
  }

  #recoverExistingRows(): void {
    this.#events.length = 0
    this.#byIdempotencyKey.clear()
    this.#draftJsonByIdempotencyKey.clear()
    this.#mutationJsonByIdempotencyKey.clear()
    this.#nextSeq = 1
    this.#runOpenedCommitted = false
    this.#terminalCommitted = false

    const eventRows = this.#dbOrThrow()
      .prepare("select event_json from events where run_id = ? order by seq")
      .all(this.#runId)
    for (const row of eventRows) {
      const text = stringColumn(row, "event_json")
      const event = parseJournalEventLine(text)
      const committed = { seq: event.seq, event }
      this.#events.push(committed)
      if (event.seq >= this.#nextSeq) this.#nextSeq = event.seq + 1
      if (event.t === "run_opened") this.#runOpenedCommitted = true
      if (event.t === "run_finished") this.#terminalCommitted = true
    }
    const keyRows = this.#dbOrThrow()
      .prepare("select idempotency_key, seq, draft_json from idempotency_keys where run_id = ?")
      .all(this.#runId)
    for (const row of keyRows) {
      const key = stringColumn(row, "idempotency_key")
      const seq = numberColumn(row, "seq")
      const committed = this.#events.find((entry) => entry.seq === seq)
      if (committed !== undefined) this.#rememberCommitted(key, committed, stringColumn(row, "draft_json"))
    }
    const mutationRows = this.#dbOrThrow()
      .prepare("select idempotency_key, mutation_json from mutations where run_id = ?")
      .all(this.#runId)
    for (const row of mutationRows) this.#mutationJsonByIdempotencyKey.set(stringColumn(row, "idempotency_key"), stringColumn(row, "mutation_json"))
  }

  #upsertRunRow(event: JournalEvent): void {
    const now = new Date().toISOString()
    const db = this.#dbOrThrow()
    if (event.t === "run_opened") {
      db.prepare(`
        insert into runs(run_id, workflow_name, script_path, script_sha256, provider, opened_at, updated_at, status)
        values(?, ?, ?, ?, ?, ?, ?, ?)
        on conflict(run_id) do update set
          workflow_name = excluded.workflow_name,
          script_path = excluded.script_path,
          script_sha256 = excluded.script_sha256,
          provider = excluded.provider,
          updated_at = excluded.updated_at,
          status = excluded.status
      `).run(this.#runId, event.workflowName, event.scriptPath, event.scriptSha256, event.provider, now, now, "queued")
      return
    }
    const status = event.t === "run_finished" ? event.status : undefined
    if (status === undefined) {
      db.prepare("update runs set updated_at = ? where run_id = ?").run(now, this.#runId)
    } else {
      db.prepare("update runs set updated_at = ?, status = ? where run_id = ?").run(now, status, this.#runId)
    }
  }

  #acquireLock(): void {
    const db = this.#dbOrThrow()
    db.exec("begin immediate")
    try {
      const row = db.prepare("select pid, acquired_at from run_locks where run_id = ?").get(this.#runId)
      if (row !== undefined) {
        const pid = numberColumn(row, "pid")
        const acquiredAt = stringColumn(row, "acquired_at")
        if (this.#processOwnsLivePid(pid) && (lockIsFresh(acquiredAt) || this.#journalHasFreshHeartbeat(pid))) {
          throw new JournalCommitConflict(`journal is locked by live runner pid ${pid}`)
        }
        db.prepare("delete from run_locks where run_id = ?").run(this.#runId)
      }
      db.prepare("insert into run_locks(run_id, pid, acquired_at) values(?, ?, ?)").run(this.#runId, this.#process.pid(), new Date().toISOString())
      db.exec("commit")
    } catch (error) {
      db.exec("rollback")
      throw error
    }
  }

  #journalHasFreshHeartbeat(pid: number): boolean {
    let lastHeartbeatMs: number | undefined
    const rows = this.#dbOrThrow()
      .prepare("select event_json from events where run_id = ? and event_type = 'runner_heartbeat' order by seq")
      .all(this.#runId)
    for (const row of rows) {
      const event = parseJournalEventLine(stringColumn(row, "event_json"))
      if (event.t === "runner_heartbeat" && event.pid === pid && event.ts !== undefined) {
        const parsed = Date.parse(event.ts)
        if (Number.isFinite(parsed)) lastHeartbeatMs = parsed
      }
    }
    if (lastHeartbeatMs === undefined) return false
    return Date.now() - lastHeartbeatMs < HEARTBEAT_STALE_MS
  }

  #processOwnsLivePid(pid: number): boolean {
    try {
      this.#process.probePid(pid)
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

  #rememberCommitted(idempotencyKey: string, committed: CommittedJournalEvent, draftJson: string): void {
    this.#byIdempotencyKey.set(idempotencyKey, committed)
    this.#draftJsonByIdempotencyKey.set(idempotencyKey, draftJson)
  }

  #dbOrThrow(): DatabaseSync {
    const db = this.#db
    if (db === undefined) throw new JournalCommitConflict("sqlite journal database is not open")
    return db
  }

  #close(): void {
    this.#db?.close()
    this.#db = undefined
    this.#opened = false
  }

  #enqueue<T>(operation: () => T | Promise<T>): Promise<T> {
    const run = this.#writeQueue.then(operation, operation)
    this.#writeQueue = run.then(() => undefined, () => undefined)
    return run
  }
}

export function initializeSqliteSchema(db: DatabaseSync): void {
  db.exec(`
    pragma journal_mode = wal;
    pragma synchronous = normal;
    create table if not exists metadata (
      key text primary key,
      value text not null
    );
    create table if not exists runs (
      run_id text primary key,
      workflow_name text not null,
      script_path text not null,
      script_sha256 text not null,
      provider text not null,
      opened_at text not null,
      updated_at text not null,
      status text not null
    );
    create table if not exists events (
      run_id text not null,
      seq integer not null,
      event_type text not null,
      event_json text not null,
      created_at text not null,
      primary key (run_id, seq)
    );
    create table if not exists idempotency_keys (
      run_id text not null,
      idempotency_key text not null,
      seq integer not null,
      draft_json text not null,
      primary key (run_id, idempotency_key)
    );
    create table if not exists mutations (
      run_id text not null,
      idempotency_key text not null,
      mutation_json text not null,
      created_at text not null,
      primary key (run_id, idempotency_key)
    );
    create table if not exists run_locks (
      run_id text primary key,
      pid integer not null,
      acquired_at text not null
    );
    create table if not exists serve_sessions (
      run_id text primary key,
      url text not null,
      pid integer not null,
      updated_at text not null
    );
    insert or ignore into metadata(key, value) values('storage_schema_version', '1');
  `)
}

type SqliteRow = Readonly<Record<string, string | number | bigint | Uint8Array | null>>

function stringColumn(row: SqliteRow, key: string): string {
  const value = row[key]
  if (value === undefined || value === null) throw new JournalCommitConflict(`sqlite column ${key} was not present`)
  return String(value)
}

function numberColumn(row: SqliteRow, key: string): number {
  const value = row[key]
  if (value === undefined || value === null) throw new JournalCommitConflict(`sqlite column ${key} was not present`)
  const parsed = Number(value)
  if (!Number.isFinite(parsed)) throw new JournalCommitConflict(`sqlite column ${key} was not numeric`)
  return parsed
}

const LOCK_FRESH_GRACE_MS = 2_000
const HEARTBEAT_STALE_MS = 30_000

function lockIsFresh(acquiredAt: string): boolean {
  const parsed = Date.parse(acquiredAt)
  if (!Number.isFinite(parsed)) return true
  return Date.now() - parsed < LOCK_FRESH_GRACE_MS
}
