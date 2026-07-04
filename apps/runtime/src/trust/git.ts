import { z } from "zod"

import type { Proven } from "../domain/brand.ts"
import type { GitWorktreeFacts } from "../domain/contracts.ts"
import { proven } from "./proven.ts"

const processResultSchema = z.object({
  exitCode: z.number().int().nullable(),
  signal: z.string().nullable(),
  stdout: z.string(),
  stderr: z.string(),
}).strict()

export function parseGitRootProbe(input: unknown): Proven<{ readonly t: "not_repo" } | { readonly t: "repo"; readonly root: string }> {
  const result = processResultSchema.parse(input)
  if (result.exitCode !== 0) return proven({ t: "not_repo" })
  const root = result.stdout.trim()
  if (root.length === 0) return proven({ t: "not_repo" })
  return proven({ t: "repo", root })
}

export function parseGitStatusProbe(input: unknown): Proven<{ readonly dirty: boolean }> {
  const result = processResultSchema.parse(input)
  return proven({ dirty: result.exitCode !== 0 || result.stdout.length > 0 })
}

export function parseGitWorktreeFacts(input: unknown): Proven<GitWorktreeFacts> {
  return proven(z.discriminatedUnion("t", [
    z.object({ t: z.literal("not_repo") }).strict(),
    z.object({ t: z.literal("repo"), root: z.string().min(1), dirty: z.boolean() }).strict(),
  ]).parse(input))
}
