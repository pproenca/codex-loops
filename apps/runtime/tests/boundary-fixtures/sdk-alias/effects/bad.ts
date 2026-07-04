import { Codex } from "@openai/codex-sdk"

import { runContainedAgentTurn } from "../../../../src/containment/agent-turn.ts"

void runContainedAgentTurn

const C = Codex

export function bad() {
  return new C()
}
