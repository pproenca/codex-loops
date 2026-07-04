import type { RunnerHeartbeatPort } from "../../ports/index.ts"

export class NodeRunnerHeartbeatPort implements RunnerHeartbeatPort {
  readonly #intervalMs: number

  constructor(input: { readonly intervalMs: number }) {
    this.#intervalMs = input.intervalMs
  }

  async start(input: Parameters<RunnerHeartbeatPort["start"]>[0]): ReturnType<RunnerHeartbeatPort["start"]> {
    let pending: Promise<void> = Promise.resolve()
    const tick = (): void => {
      pending = pending.then(() => input.writeHeartbeat()).catch(() => {})
    }
    const timer = setInterval(tick, this.#intervalMs)
    timer.unref()
    return {
      async stop() {
        clearInterval(timer)
        await pending
      },
    }
  }
}
