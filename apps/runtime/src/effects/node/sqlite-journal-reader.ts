import { DatabaseSync } from "node:sqlite"

import type { JournalRunCandidate } from "../../domain/contracts.ts"
import type { JournalDirectoryPort, JournalReader } from "../../ports/index.ts"

export class SqliteJournalReader implements JournalReader {
  readonly #databasePath: string

  constructor(databasePath: string) {
    this.#databasePath = databasePath
  }

  async resolveRun(input: Parameters<JournalReader["resolveRun"]>[0]): Promise<{ readonly runId: string; readonly databasePath: string }> {
    const runId = this.#runIdFor(input.runId)
    return { runId, databasePath: this.#databasePath }
  }

  async readText(runId: string): Promise<string> {
    const resolvedRunId = this.#runIdFor(runId)
    const db = openReadDatabase(this.#databasePath)
    try {
      const rows = db.prepare("select event_json from events where run_id = ? order by seq").all(resolvedRunId)
      if (rows.length === 0) throw new Error(`workflow run not found: ${resolvedRunId}`)
      return `${rows.map((row) => stringColumn(row, "event_json")).join("\n")}\n`
    } finally {
      db.close()
    }
  }

  async readMutationText(runId: string): Promise<string> {
    const resolvedRunId = this.#runIdFor(runId)
    const db = openReadDatabase(this.#databasePath)
    try {
      const rows = db.prepare("select mutation_json from mutations where run_id = ? order by created_at, idempotency_key").all(resolvedRunId)
      if (rows.length === 0) throw Object.assign(new Error("no mutation records"), { code: "ENOENT" })
      return `${rows.map((row) => stringColumn(row, "mutation_json")).join("\n")}\n`
    } finally {
      db.close()
    }
  }

  #runIdFor(runId: string): string {
    if (runId === "latest") {
      const db = openReadDatabase(this.#databasePath)
      try {
        const row = db.prepare("select value from metadata where key = 'latest_run_id'").get()
        if (row === undefined) throw new Error("no latest workflow run is recorded")
        return stringColumn(row, "value")
      } finally {
        db.close()
      }
    }
    if (runId.length === 0) throw new Error("workflow run id must be non-empty")
    return runId
  }
}

export class SqliteJournalDirectory implements JournalDirectoryPort {
  readonly #databasePath: string

  constructor(databasePath: string) {
    this.#databasePath = databasePath
  }

  async listRuns(): Promise<readonly JournalRunCandidate[]> {
    const db = openReadDatabase(this.#databasePath)
    try {
      return db.prepare("select run_id, updated_at from runs order by updated_at desc, run_id desc").all().map((row) => ({
        runId: stringColumn(row, "run_id"),
        databasePath: this.#databasePath,
        updatedAt: stringColumn(row, "updated_at"),
      }))
    } finally {
      db.close()
    }
  }
}

function openReadDatabase(databasePath: string): DatabaseSync {
  const db = new DatabaseSync(databasePath, { timeout: 5_000 })
  initializeSqliteReadSchema(db)
  return db
}

function initializeSqliteReadSchema(db: DatabaseSync): void {
  db.exec(`
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
    create table if not exists mutations (
      run_id text not null,
      idempotency_key text not null,
      mutation_json text not null,
      created_at text not null,
      primary key (run_id, idempotency_key)
    );
    insert or ignore into metadata(key, value) values('storage_schema_version', '1');
  `)
}

type SqliteRow = Readonly<Record<string, string | number | bigint | Uint8Array | null>>

function stringColumn(row: SqliteRow, key: string): string {
  const value = row[key]
  if (value === undefined || value === null) throw new Error(`sqlite column ${key} was not present`)
  return String(value)
}
