export const store = {
  async commit() {
    return { seq: 1, event: { seq: 1, t: "run_finished", status: "done", totalTokens: 0, totalToolCalls: 0, durationMs: 0 } }
  },
  async initializeRun() {
    return { seq: 1, event: { seq: 1, t: "run_finished", status: "done", totalTokens: 0, totalToolCalls: 0, durationMs: 0 } }
  },
}
