import { z } from "zod"

import type { Proven } from "../domain/brand.ts"
import type { CliRequest, ServeCommandRequest } from "../domain/contracts.ts"
import { CliUsageError } from "./cli-error.ts"
import { proven } from "./proven.ts"

const DEFAULT_RUN_ID = "latest"
const SERVE_EVENT_LIMIT = 40
const SERVE_LIVE_POLL_MS = 250
const flagValueSchema = z.union([z.string(), z.boolean()])

export function parseServeCliRequest(input: Proven<CliRequest>): Proven<ServeCommandRequest> {
  const command = z.literal("serve").parse(input.command)
  const flags = z.record(z.string(), flagValueSchema).parse(input.flags)
  rejectRemovedJournal(flags["journal"])
  return proven({
    command,
    runId: parseRunId(flags["run-id"]),
    host: parseHost(flags["host"]),
    port: parsePort(flags["port"]),
    eventLimit: SERVE_EVENT_LIMIT,
    livePollMs: SERVE_LIVE_POLL_MS,
    json: flags["json"] === true,
    quiet: flags["quiet"] === true,
  })
}

function parseRunId(value: string | boolean | undefined): string {
  if (value === undefined) return DEFAULT_RUN_ID
  if (typeof value === "string" && value.length > 0) {
    return value
  }
  throw new CliUsageError("--run-id must be a non-empty string")
}

function rejectRemovedJournal(value: string | boolean | undefined): void {
  if (value !== undefined) throw new CliUsageError("--journal was removed; use --run-id")
}

function parseHost(value: string | boolean | undefined): string {
  if (value === undefined) return "127.0.0.1"
  if (typeof value === "string" && value.length > 0) return value
  throw new CliUsageError("--host must be a non-empty string")
}

function parsePort(value: string | boolean | undefined): number {
  if (value === undefined) return 0
  if (typeof value !== "string") throw new CliUsageError("--port must be a number")
  const parsed = Number(value)
  if (!Number.isInteger(parsed) || parsed < 0 || parsed > 65535) throw new CliUsageError("--port must be an integer between 0 and 65535")
  return parsed
}
