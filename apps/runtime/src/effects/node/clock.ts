import type { ClockPort } from "../../ports/index.ts"

export class SystemClock implements ClockPort {
  nowMs(): number {
    return Date.now()
  }
}
