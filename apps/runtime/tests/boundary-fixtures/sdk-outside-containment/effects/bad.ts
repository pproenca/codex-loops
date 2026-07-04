import { Codex } from "@openai/codex-sdk"

import { runContainedAgentTurn } from "../../../../src/containment/agent-turn.ts"

export async function bad() {
  await runContainedAgentTurn({
    policy: { wallTimeoutMs: 1, idleTimeoutMs: 1 },
    callerSignal: new AbortController().signal,
    operation: async () => [],
  })
  return new Codex()
}
