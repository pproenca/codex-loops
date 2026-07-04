import type { AgentProgressDecision, AgentProgressSnapshot, ProviderEvent } from "../domain/contracts.ts"

export type AgentProgressInput = {
  readonly previous: AgentProgressSnapshot
  readonly event: ProviderEvent
  readonly nowMs: number
}

export function decideAgentProgress(input: AgentProgressInput): AgentProgressDecision {
  switch (input.event.t) {
    case "thread_bound":
      if (input.previous.thread.t === "bound" && input.previous.thread.threadId === input.event.threadId) {
        return { t: "ignore_progress", reason: "unchanged" }
      }
      return { t: "commit_thread_binding", threadId: input.event.threadId }
    case "message_observed":
      return { t: "commit_progress", next: { ...input.previous, lastProgressAtMs: input.nowMs } }
    case "tool_observed":
      return {
        t: "commit_progress",
        next: {
          ...input.previous,
          toolCalls: input.previous.toolCalls + 1,
          lastTool: { t: "observed", name: input.event.name, summary: input.event.summary },
          lastProgressAtMs: input.nowMs,
        },
      }
    case "file_mutations_observed":
      return {
        t: "commit_progress",
        next: {
          ...input.previous,
          mutationFiles: [...input.previous.mutationFiles, ...input.event.files.map((file) => file.path)],
          lastProgressAtMs: input.nowMs,
        },
      }
    case "usage_observed":
      return {
        t: "commit_progress",
        next: {
          ...input.previous,
          tokens: input.event.inputTokens + input.event.outputTokens,
          lastProgressAtMs: input.nowMs,
        },
      }
    case "provider_failed":
      return { t: "ignore_progress", reason: "unchanged" }
    case "unknown_telemetry":
      return { t: "ignore_progress", reason: "telemetry_only" }
  }
}

export function initialAgentProgressSnapshot(input: { readonly threadId?: string | undefined }): AgentProgressSnapshot {
  return {
    thread: input.threadId === undefined ? { t: "unbound" } : { t: "bound", threadId: input.threadId },
    tokens: 0,
    toolCalls: 0,
    mutationFiles: [],
    lastTool: { t: "none" },
    lastProgressAtMs: 0,
  }
}
