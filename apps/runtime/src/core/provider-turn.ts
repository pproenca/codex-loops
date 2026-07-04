import type { ProviderEvent, ThreadBinding, ToolObservation } from "../domain/contracts.ts"

export type ProviderTurnState = {
  readonly thread: ThreadBinding
  readonly finalText: string
  readonly tokens: number
  readonly toolCalls: number
  readonly mutationFiles: readonly string[]
  readonly lastTool: ToolObservation
  readonly failure:
    | { readonly t: "none" }
    | { readonly t: "failed"; readonly message: string }
}

export type ProviderTurnCompletion =
  | {
    readonly t: "completed"
    readonly finalText: string
    readonly thread: ThreadBinding
    readonly tokens: number
    readonly toolCalls: number
    readonly mutationFiles: readonly string[]
  }
  | {
    readonly t: "failed"
    readonly message: string
    readonly tokens: number
    readonly toolCalls: number
    readonly mutationFiles: readonly string[]
  }

export type StructuredOutputRetryDecision =
  | { readonly t: "retry" }
  | { readonly t: "fail_closed"; readonly message: string }

export function initialProviderTurnState(): ProviderTurnState {
  return {
    thread: { t: "unbound" },
    finalText: "",
    tokens: 0,
    toolCalls: 0,
    mutationFiles: [],
    lastTool: { t: "none" },
    failure: { t: "none" },
  }
}

export function frameWorkflowWorkerPrompt(input: {
  readonly prompt: string
  readonly label: string
  readonly phaseTitle?: string | undefined
}): string {
  return [
    "You are a subagent spawned by an Codex Loops workflow orchestration script.",
    "Start cold: inspect the repository and re-derive only the context needed for this task.",
    "Do not coordinate with or inspect other workflow agents. The host will aggregate results.",
    "Use available tools to complete the assigned task, and keep the response scoped to the prompt.",
    `Workflow node label: ${input.label}`,
    input.phaseTitle === undefined ? undefined : `Workflow phase: ${input.phaseTitle}`,
    "",
    input.prompt,
  ].filter((line) => line !== undefined).join("\n")
}

export function foldProviderTurnEvent(state: ProviderTurnState, event: ProviderEvent): ProviderTurnState {
  switch (event.t) {
    case "thread_bound":
      return { ...state, thread: { t: "bound", threadId: event.threadId } }
    case "message_observed":
      return { ...state, finalText: event.text }
    case "tool_observed":
      return {
        ...state,
        toolCalls: state.toolCalls + 1,
        lastTool: { t: "observed", name: event.name, summary: event.summary },
      }
    case "file_mutations_observed":
      return { ...state, mutationFiles: [...state.mutationFiles, ...event.files.map((file) => file.path)] }
    case "usage_observed":
      return { ...state, tokens: event.inputTokens + event.outputTokens }
    case "provider_failed":
      return { ...state, failure: { t: "failed", message: event.message } }
    case "unknown_telemetry":
      return state
  }
}

export function decideProviderTurnCompletion(input: {
  readonly state: ProviderTurnState
  readonly maxMutationFilesPerAgent: number
}): ProviderTurnCompletion {
  switch (input.state.failure.t) {
    case "failed":
      return {
        t: "failed",
        message: input.state.failure.message,
        tokens: input.state.tokens,
        toolCalls: input.state.toolCalls,
        mutationFiles: input.state.mutationFiles,
      }
    case "none":
      {
        if (input.state.mutationFiles.length > input.maxMutationFilesPerAgent) {
          return {
            t: "failed",
            message: `agent file mutations exceeded maxMutationFilesPerAgent ${input.maxMutationFilesPerAgent}`,
            tokens: input.state.tokens,
            toolCalls: input.state.toolCalls,
            mutationFiles: input.state.mutationFiles,
          }
        }
        return {
          t: "completed",
          finalText: input.state.finalText,
          thread: input.state.thread,
          tokens: input.state.tokens,
          toolCalls: input.state.toolCalls,
          mutationFiles: input.state.mutationFiles,
        }
      }
  }
}

export function decideStructuredOutputRetry(input: {
  readonly isolation?: "read-only" | "workspace-write" | "worktree" | "full-access" | undefined
  readonly mutationFiles: readonly string[]
}): StructuredOutputRetryDecision {
  if (input.mutationFiles.length > 0) {
    return { t: "fail_closed", message: "structured output retry refused after observed file mutations" }
  }
  switch (input.isolation) {
    case "workspace-write":
    case "worktree":
    case "full-access":
      return { t: "fail_closed", message: `structured output retry refused for ${input.isolation} isolation without an idempotent write transaction` }
    case "read-only":
      return { t: "retry" }
    case undefined:
      return { t: "fail_closed", message: "structured output retry refused without explicit isolation" }
  }
}
