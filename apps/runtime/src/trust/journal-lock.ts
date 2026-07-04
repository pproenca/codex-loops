import { z } from "zod"

import type { Proven } from "../domain/brand.ts"
import { proven } from "./proven.ts"

export type JournalLockFacts =
  | { readonly t: "pid"; readonly pid: number }
  | { readonly t: "malformed" }

const pidTextSchema = z.string().regex(/^[1-9][0-9]*\n?$/)

export function parseJournalLockText(text: string): Proven<JournalLockFacts> {
  const parsed = pidTextSchema.safeParse(text)
  if (!parsed.success) return proven({ t: "malformed" })
  const pid = Number.parseInt(parsed.data.trim(), 10)
  if (!Number.isSafeInteger(pid) || pid < 1) return proven({ t: "malformed" })
  return proven({ t: "pid", pid })
}
