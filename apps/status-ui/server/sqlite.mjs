import { homedir } from "node:os"
import { join } from "node:path"
import { DatabaseSync } from "node:sqlite"

export const WORKFLOW_RUN_STORAGE_SCHEMA_VERSION = 1

export function defaultWorkflowDatabasePath(home = homedir()) {
  return join(home, ".codex", "workflows", `runs_${WORKFLOW_RUN_STORAGE_SCHEMA_VERSION}.sqlite`)
}

export function readRunEvents(input) {
  const resolved = resolveRun(input)
  const db = new DatabaseSync(input.databasePath, { readOnly: true, timeout: 5_000 })
  try {
    const rows = db.prepare("select event_json from events where run_id = ? order by seq").all(resolved.runId)
    if (rows.length === 0) throw new Error(`run ${resolved.runId} was not found in ${input.databasePath}`)
    return {
      ...resolved,
      events: rows.map((row) => parseEventJson(String(row.event_json))),
    }
  } finally {
    db.close()
  }
}

export function resolveRun(input) {
  const db = new DatabaseSync(input.databasePath, { readOnly: true, timeout: 5_000 })
  try {
    const runId = input.selector === "latest" ? readLatestRunId(db, input.databasePath) : input.selector
    const row = db.prepare("select 1 from events where run_id = ? limit 1").get(runId)
    if (row === undefined) throw new Error(`run ${runId} was not found in ${input.databasePath}`)
    return { runId, databasePath: input.databasePath }
  } finally {
    db.close()
  }
}

function readLatestRunId(db, databasePath) {
  const row = db.prepare("select value from metadata where key = 'latest_run_id'").get()
  if (row === undefined) throw new Error(`no latest workflow run in ${databasePath}`)
  return String(row.value)
}

function parseEventJson(text) {
  const value = JSON.parse(text)
  if (value === null || typeof value !== "object" || Array.isArray(value)) throw new Error("journal event row must be a JSON object")
  if (typeof value.t !== "string") throw new Error("journal event is missing type")
  return value
}
