import assert from "node:assert/strict"
import { test } from "node:test"

import { decideAgentProgress } from "../src/core/agent-progress.ts"
import { decideProviderTurnCompletion, decideStructuredOutputRetry, foldProviderTurnEvent, frameWorkflowWorkerPrompt, initialProviderTurnState } from "../src/core/provider-turn.ts"
import type { AgentProgressSnapshot } from "../src/domain/contracts.ts"

const previous: AgentProgressSnapshot = {
  thread: { t: "unbound" },
  tokens: 0,
  toolCalls: 0,
  mutationFiles: [],
  lastTool: { t: "none" },
  lastProgressAtMs: 0,
}

test("core decides from parsed provider-domain events", () => {
  assert.deepEqual(decideAgentProgress({
    previous,
    event: { t: "thread_bound", threadId: "thread-1" },
    nowMs: 10,
  }), { t: "commit_thread_binding", threadId: "thread-1" })

  assert.deepEqual(decideAgentProgress({
    previous,
    event: { t: "usage_observed", inputTokens: 3, outputTokens: 5 },
    nowMs: 10,
  }), {
    t: "commit_progress",
    next: {
      ...previous,
      tokens: 8,
      lastProgressAtMs: 10,
    },
  })

  assert.deepEqual(decideAgentProgress({
    previous,
    event: {
      t: "file_mutations_observed",
      files: [
        { path: "a.ts", operation: "created" },
        { path: "b.ts", operation: "updated" },
      ],
    },
    nowMs: 10,
  }), {
    t: "commit_progress",
    next: {
      ...previous,
      mutationFiles: ["a.ts", "b.ts"],
      lastProgressAtMs: 10,
    },
  })
})

test("core fails provider turns that exceed parsed mutation limits", () => {
  const state = foldProviderTurnEvent(
    initialProviderTurnState(),
    {
      t: "file_mutations_observed",
      files: [
        { path: "a.ts", operation: "created" },
        { path: "b.ts", operation: "updated" },
      ],
    },
  )

  assert.deepEqual(decideProviderTurnCompletion({ state, maxMutationFilesPerAgent: 1 }), {
    t: "failed",
    message: "agent file mutations exceeded maxMutationFilesPerAgent 1",
    tokens: 0,
    toolCalls: 0,
    mutationFiles: ["a.ts", "b.ts"],
  })
})

test("core fails structured output retry closed without explicit read-only isolation", () => {
  assert.deepEqual(decideStructuredOutputRetry({ isolation: "read-only", mutationFiles: [] }), { t: "retry" })
  assert.deepEqual(decideStructuredOutputRetry({ isolation: undefined, mutationFiles: [] }), {
    t: "fail_closed",
    message: "structured output retry refused without explicit isolation",
  })
})

test("core frames workflow worker prompts deterministically", () => {
  const prompt = "Inspect the package contract and report exact findings."
  const framed = frameWorkflowWorkerPrompt({ prompt, label: "contract-review" })

  assert.ok(framed.startsWith("You are a subagent spawned by an Codex Loops workflow orchestration script."))
  assert.ok(framed.includes("Workflow node label: contract-review"))
  assert.ok(framed.endsWith(prompt))
  assert.equal(framed, frameWorkflowWorkerPrompt({ prompt, label: "contract-review" }))
})
