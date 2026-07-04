import { z } from "zod"

import type { Proven } from "../domain/brand.ts"
import type { ServePortfileRecord } from "../domain/contracts.ts"
import { proven } from "./proven.ts"

const servePortfileSchema = z.object({
  url: z.string().url(),
  pid: z.number().int().positive(),
}).strict()

export function parseServePortfileText(text: string): Proven<Pick<ServePortfileRecord, "url" | "pid">> {
  return proven(servePortfileSchema.parse(JSON.parse(text)))
}
