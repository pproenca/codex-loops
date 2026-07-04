import { proven } from "../../../../src/trust/proven.ts"

export function mint() {
  return proven({ forged: true })
}
