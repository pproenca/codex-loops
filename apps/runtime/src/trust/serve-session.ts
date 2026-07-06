import { z } from "zod"

import type { Proven } from "../domain/brand.ts"
import type { ServeSessionRecord } from "../domain/contracts.ts"
import { proven } from "./proven.ts"

const serveSessionSchema = z.object({
  url: z.string().url(),
  pid: z.number().int().positive(),
}).strict()

export function parseServeSessionText(text: string): Proven<Pick<ServeSessionRecord, "url" | "pid">> {
  return proven(serveSessionSchema.parse(JSON.parse(text)))
}
