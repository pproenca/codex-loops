import { parseJsonValue } from "../../../../src/trust/json.ts"

export function badEffect(value: unknown): void {
  parseJsonValue(value)
}
