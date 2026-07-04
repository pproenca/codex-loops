import { z } from "zod"

import type { Proven } from "../domain/brand.ts"
import type { CliRequest, DraftCommandRequest } from "../domain/contracts.ts"
import { CliUsageError } from "./cli-error.ts"
import { proven } from "./proven.ts"

export function parseDraftCliRequest(input: Proven<CliRequest>): Proven<DraftCommandRequest> {
  const flags = z.record(z.string(), z.union([z.string(), z.boolean()])).parse(input.flags)
  const goal = parseGoal({ flag: flags["goal"], positionals: input.args })
  const name = optionalString(flags["name"], "--name")
  const output = optionalString(flags["output"], "--output")
  const cwd = optionalString(flags["cwd"], "--cwd")
  return proven({
    command: "draft",
    goal,
    ...(name === undefined ? {} : { name }),
    ...(output === undefined ? {} : { output }),
    ...(cwd === undefined ? {} : { cwd }),
    json: flags["json"] === true,
    quiet: flags["quiet"] === true,
  })
}

function parseGoal(input: { readonly flag: string | boolean | undefined; readonly positionals: readonly string[] }): string {
  if (input.flag !== undefined) {
    if (typeof input.flag !== "string" || input.flag.trim().length === 0) throw new CliUsageError("draft requires --goal <text>")
    return input.flag.trim()
  }
  const joined = input.positionals.join(" ").trim()
  if (joined.length === 0) throw new CliUsageError("draft requires --goal <text>")
  return joined
}

function optionalString(value: string | boolean | undefined, label: string): string | undefined {
  if (value === undefined) return undefined
  if (typeof value === "string" && value.length > 0) return value
  throw new CliUsageError(`${label} must be a non-empty string`)
}
