import { homedir } from "node:os"
import { join } from "node:path"

export const WORKFLOW_RUN_STORAGE_SCHEMA_VERSION = 1

export function defaultWorkflowDatabasePath(home?: string | undefined): string {
  const root = home === undefined ? homedir() : home
  return join(root, ".codex", "workflows", `runs_${WORKFLOW_RUN_STORAGE_SCHEMA_VERSION}.sqlite`)
}
