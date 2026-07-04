import { z } from "zod"

import type { Proven } from "../domain/brand.ts"
import type { JournalPointerTarget, JournalPointerText } from "../domain/contracts.ts"
import { proven } from "./proven.ts"

const pointerTargetSchema = z.string().min(1)
  .refine((target) => !target.startsWith("/"), "journal pointer target must be relative")
  .refine((target) => !target.includes("\0"), "journal pointer target must not contain NUL")
  .refine((target) => target.split(/[\\/]+/).every((segment) => segment !== "." && segment !== ".."), "journal pointer target must not traverse directories")

const pointerSchema = z.object({
  $pointer: pointerTargetSchema,
}).strict()

export function parseJournalPointerText(text: string): Proven<JournalPointerText> {
  let parsed: unknown
  try {
    parsed = JSON.parse(text)
  } catch {
    return proven({ t: "content" })
  }
  const result = pointerSchema.safeParse(parsed)
  if (result.success) return proven({ t: "pointer", target: pointerTarget(result.data.$pointer) })
  if (parsed !== null && typeof parsed === "object" && "$pointer" in parsed) throw result.error
  return proven({ t: "content" })
}

function pointerTarget(value: string): JournalPointerTarget {
  return value as JournalPointerTarget
}
