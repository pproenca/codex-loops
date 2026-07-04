import { Codex } from "@openai/codex-sdk"

import { runContainedAgentTurn } from "../../../../src/containment/agent-turn.ts"

export async function bad() {
  {
    const runContainedAgentTurn = async (input: {
      readonly operation: () => Promise<unknown>
    }): Promise<unknown> => input.operation()

    return runContainedAgentTurn({
      operation: async () => new Codex(),
    })
  }
}
