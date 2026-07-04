import { z } from "zod"

import type { Proven } from "../domain/brand.ts"
import type { JsonValue } from "../domain/json.ts"
import { proven } from "./proven.ts"

const jsonPrimitiveSchema = z.union([z.string(), z.number().finite(), z.boolean(), z.null()])

export const jsonValueSchema: z.ZodType<JsonValue> = z.lazy(() => z.union([
  jsonPrimitiveSchema,
  z.array(jsonValueSchema),
  z.record(z.string(), jsonValueSchema),
]))

export function parseJsonValue(input: unknown): Proven<JsonValue> {
  return proven(jsonValueSchema.parse(input))
}

export function parseJsonText(input: string): Proven<JsonValue> {
  return parseJsonValue(JSON.parse(input))
}
