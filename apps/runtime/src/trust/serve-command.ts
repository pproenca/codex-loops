import { z } from "zod"

import type { Proven } from "../domain/brand.ts"
import type { CliRequest, ServeCommandRequest } from "../domain/contracts.ts"
import { CliUsageError } from "./cli-error.ts"
import { proven } from "./proven.ts"

const DEFAULT_JOURNAL_PATH = ".agent-loops-runs/latest.json"
const SERVE_EVENT_LIMIT = 40
const SERVE_LIVE_POLL_MS = 250
const flagValueSchema = z.union([z.string(), z.boolean()])

export function parseServeCliRequest(input: Proven<CliRequest>): Proven<ServeCommandRequest> {
  const command = z.literal("serve").parse(input.command)
  const flags = z.record(z.string(), flagValueSchema).parse(input.flags)
  return proven({
    command,
    journalPath: parseJournalPath(flags["journal"]),
    host: parseHost(flags["host"]),
    port: parsePort(flags["port"]),
    eventLimit: SERVE_EVENT_LIMIT,
    livePollMs: SERVE_LIVE_POLL_MS,
    json: flags["json"] === true,
    quiet: flags["quiet"] === true,
  })
}

function parseJournalPath(value: string | boolean | undefined): string {
  if (value === undefined) return DEFAULT_JOURNAL_PATH
  if (typeof value === "string" && value.length > 0) return value
  throw new CliUsageError("--journal must be a non-empty string")
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
