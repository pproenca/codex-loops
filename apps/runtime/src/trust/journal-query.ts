import { z } from "zod"

import type { Proven } from "../domain/brand.ts"
import type { CliRequest, JournalListRequest, JournalQueryRequest } from "../domain/contracts.ts"
import { CliUsageError } from "./cli-error.ts"
import { proven } from "./proven.ts"

const DEFAULT_JOURNAL_PATH = ".agent-loops-runs/latest.json"

export function parseJournalQueryCliRequest(input: Proven<CliRequest>): Proven<JournalQueryRequest> {
  const command = z.enum(["inspect", "status"]).parse(input.command)
  const flags = z.record(z.string(), z.union([z.string(), z.boolean()])).parse(input.flags)
  const journalPath = parseJournalPath(flags["journal"])
  const json = flags["json"] === true

  if (command === "inspect") return proven({ command, journalPath, json })
  return proven({
    command,
    journalPath,
    eventLimit: parseEventLimit(flags["event-limit"]),
    json,
  })
}

export function parseJournalListCliRequest(input: Proven<CliRequest>): Proven<JournalListRequest> {
  const command = z.literal("list").parse(input.command)
  const flags = z.record(z.string(), z.union([z.string(), z.boolean()])).parse(input.flags)
  return proven({
    command,
    journalRoot: parseJournalRoot(flags["journal-root"]),
    limit: parsePositiveLimit(flags["limit"]),
    eventLimit: parseEventLimit(flags["event-limit"]),
    json: flags["json"] === true,
  })
}

function parseJournalPath(value: string | boolean | undefined): string {
  if (value === undefined) return DEFAULT_JOURNAL_PATH
  if (typeof value === "string" && value.length > 0) return value
  throw new CliUsageError("--journal must be a non-empty string")
}

function parseEventLimit(value: string | boolean | undefined): number {
  if (value === undefined) return 5
  if (typeof value !== "string") throw new CliUsageError("--event-limit must be a number")
  const parsed = Number(value)
  if (!Number.isInteger(parsed) || parsed < 0) throw new CliUsageError("--event-limit must be a non-negative integer")
  return parsed
}

function parseJournalRoot(value: string | boolean | undefined): string {
  if (value === undefined) return ".agent-loops-runs"
  if (typeof value === "string" && value.length > 0) return value
  throw new CliUsageError("--journal-root must be a non-empty string")
}

function parsePositiveLimit(value: string | boolean | undefined): number {
  if (value === undefined) return 20
  if (typeof value !== "string") throw new CliUsageError("--limit must be a number")
  const parsed = Number(value)
  if (!Number.isInteger(parsed) || parsed < 1) throw new CliUsageError("--limit must be a positive integer")
  return parsed
}
