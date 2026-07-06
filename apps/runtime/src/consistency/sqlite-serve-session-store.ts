import { mkdirSync } from "node:fs"
import { dirname } from "node:path"
import { DatabaseSync } from "node:sqlite"

import type { ServeSessionRecord } from "../domain/contracts.ts"
import type { ServeSessionStore } from "../ports/index.ts"
import { CliUsageError } from "../trust/cli-error.ts"
import { initializeSqliteSchema } from "./sqlite-journal-store.ts"

export class SqliteServeSessionStore implements ServeSessionStore {
  readonly #databasePath: string

  constructor(databasePath: string) {
    this.#databasePath = databasePath
  }

  async writeSession(record: ServeSessionRecord): Promise<void> {
    const db = openDatabase(this.#databasePath)
    try {
      db.prepare(`
        insert into serve_sessions(run_id, url, pid, updated_at) values(?, ?, ?, ?)
        on conflict(run_id) do update set url = excluded.url, pid = excluded.pid, updated_at = excluded.updated_at
      `).run(record.runId, record.url, record.pid, new Date().toISOString())
    } finally {
      db.close()
    }
  }

  async readSession(runId: string): Promise<string> {
    validateRunId(runId)
    const db = openDatabase(this.#databasePath)
    try {
      const row = db.prepare("select url, pid from serve_sessions where run_id = ?").get(runId)
      if (row === undefined) throw Object.assign(new Error("serve session not found"), { code: "ENOENT" })
      return `${JSON.stringify({ url: stringColumn(row, "url"), pid: numberColumn(row, "pid") })}\n`
    } finally {
      db.close()
    }
  }

  async removeSession(runId: string): Promise<void> {
    validateRunId(runId)
    const db = openDatabase(this.#databasePath)
    try {
      db.prepare("delete from serve_sessions where run_id = ?").run(runId)
    } finally {
      db.close()
    }
  }
}

function openDatabase(databasePath: string): DatabaseSync {
  mkdirSync(dirname(databasePath), { recursive: true })
  const db = new DatabaseSync(databasePath, { timeout: 5_000 })
  initializeSqliteSchema(db)
  return db
}

function validateRunId(runId: string): void {
  if (runId.length === 0) throw new CliUsageError("serve session run id must be non-empty")
}

type SqliteRow = Readonly<Record<string, string | number | bigint | Uint8Array | null>>

function stringColumn(row: SqliteRow, key: string): string {
  const value = row[key]
  if (value === undefined || value === null) throw new CliUsageError(`sqlite column ${key} was not present`)
  return String(value)
}

function numberColumn(row: SqliteRow, key: string): number {
  const value = row[key]
  if (value === undefined || value === null) throw new CliUsageError(`sqlite column ${key} was not present`)
  const parsed = Number(value)
  if (!Number.isFinite(parsed)) throw new CliUsageError(`sqlite column ${key} was not numeric`)
  return parsed
}
