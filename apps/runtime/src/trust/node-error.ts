import { z } from "zod"

import type { Proven } from "../domain/brand.ts"
import { proven } from "./proven.ts"

export type NodeErrorFacts =
  | { readonly t: "coded"; readonly code: string; readonly message: string }
  | { readonly t: "uncoded"; readonly message: string }

const errorShape = z.object({
  code: z.string().optional(),
  message: z.string().optional(),
}).passthrough()

export function parseNodeErrorFacts(error: unknown): Proven<NodeErrorFacts> {
  const parsed = errorShape.safeParse(error)
  if (parsed.success && parsed.data.code !== undefined) {
    return proven({
      t: "coded",
      code: parsed.data.code,
      message: parsed.data.message ?? parsed.data.code,
    })
  }
  if (parsed.success && parsed.data.message !== undefined) {
    return proven({ t: "uncoded", message: parsed.data.message })
  }
  return proven({ t: "uncoded", message: String(error) })
}
