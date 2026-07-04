import { Codex } from "@openai/codex-sdk"

import { runContainedAgentTurn as realContainedTurn } from "../../../../src/containment/agent-turn.ts"

void realContainedTurn

async function runContainedAgentTurn(input: {
  readonly operation: () => Promise<unknown>
}): Promise<unknown> {
  return input.operation()
}

export async function bad() {
  return runContainedAgentTurn({
    operation: async () => new Codex(),
  })
}
