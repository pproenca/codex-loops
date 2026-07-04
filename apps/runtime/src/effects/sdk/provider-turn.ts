import { Codex, type CodexOptions, type SandboxMode, type ThreadOptions, type TurnOptions } from "@openai/codex-sdk"

import { runContainedAgentTurn } from "../../containment/agent-turn.ts"
import type { ContainmentPolicy } from "../../domain/contracts.ts"
import type { ProviderAgentTurnOutput, ProviderAgentTurnPort, ProviderAgentTurnRequest } from "../../ports/index.ts"

export class SdkProviderAgentTurnPort implements ProviderAgentTurnPort {
  readonly #policy: ContainmentPolicy

  constructor(policy: ContainmentPolicy) {
    this.#policy = policy
  }

  async runAgentTurn(request: ProviderAgentTurnRequest): Promise<ProviderAgentTurnOutput> {
    return runContainedAgentTurn({
      policy: this.#policy,
      callerSignal: request.callerSignal,
      operation: async (scope) => {
        const startedAt = performance.now()
        const codex = new Codex(codexOptionsFor(request))
        const thread = request.threadId === undefined
          ? codex.startThread(threadOptionsFor(request))
          : codex.resumeThread(request.threadId, threadOptionsFor(request))
        const streamed = await thread.runStreamed(request.prompt, turnOptionsFor({ request, signal: scope.signal }))
        const events = []
        for await (const event of streamed.events) {
          scope.recordProgress()
          const wrapped = { value: event }
          await request.onStreamEvent(wrapped)
          events.push(wrapped)
        }
        return {
          events,
          durationMs: Math.round(performance.now() - startedAt),
        }
      },
    })
  }
}

function codexOptionsFor(request: ProviderAgentTurnRequest): CodexOptions {
  const options: CodexOptions = {}
  if (request.codexBaseUrl !== undefined) options.baseUrl = request.codexBaseUrl
  if (request.codexPathOverride !== undefined) options.codexPathOverride = request.codexPathOverride
  if (request.codexConfig !== undefined) options.config = request.codexConfig
  return options
}

function threadOptionsFor(request: ProviderAgentTurnRequest): ThreadOptions {
  const options: ThreadOptions = { modelReasoningEffort: request.effort }
  if (request.model !== undefined) options.model = request.model
  if (request.workingDirectory !== undefined) options.workingDirectory = request.workingDirectory
  if (request.skipGitRepoCheck) options.skipGitRepoCheck = request.skipGitRepoCheck
  const sandboxMode = sandboxModeForIsolation(request.isolation)
  if (sandboxMode !== undefined) options.sandboxMode = sandboxMode
  return options
}

function turnOptionsFor(input: { readonly request: ProviderAgentTurnRequest; readonly signal: AbortSignal }): TurnOptions {
  return {
    signal: input.signal,
    ...(input.request.schema === undefined ? {} : { outputSchema: input.request.schema }),
  }
}

function sandboxModeForIsolation(isolation: ProviderAgentTurnRequest["isolation"]): SandboxMode | undefined {
  switch (isolation) {
    case "read-only":
      return "read-only"
    case "workspace-write":
    case "worktree":
      return "workspace-write"
    case "full-access":
      return "danger-full-access"
    case undefined:
      return undefined
  }
}
