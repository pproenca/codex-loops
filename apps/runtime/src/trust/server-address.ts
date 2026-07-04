import { z } from "zod"

import type { Proven } from "../domain/brand.ts"
import { proven } from "./proven.ts"

export type ServerUrl = {
  readonly url: string
}

const addressSchema = z.object({
  address: z.string().min(1),
  port: z.number().int().min(0).max(65535),
}).passthrough()

export function parseServerAddress(input: unknown): Proven<ServerUrl> {
  const address = addressSchema.parse(input)
  return proven({ url: `http://${urlHost(address.address)}:${address.port}/` })
}

function urlHost(address: string): string {
  if (address.includes(":") && !address.startsWith("[")) return `[${address}]`
  return address
}
