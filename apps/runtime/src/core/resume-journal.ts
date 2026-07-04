import { foldJournal, toWorkflowSnapshot } from "./journal-projection.ts"
import type { JournalReadResult, PreparedWorkflowRun, ResumeCommandRequest, WorkflowApiResult, WorkflowReplayPlan } from "../domain/contracts.ts"

export type ResumeJournalDecision =
  | { readonly t: "completed"; readonly result: Extract<WorkflowApiResult, { readonly status: "completed" }> }
  | { readonly t: "resume"; readonly replay: WorkflowReplayPlan }

export function decideResumeFromJournal(input: {
  readonly request: ResumeCommandRequest
  readonly read: JournalReadResult
  readonly journalPath: string
  readonly mutationFiles: readonly string[]
}): ResumeJournalDecision {
  const state = foldJournal(input.read)
  switch (state.status) {
    case "done":
    case "failed":
    case "killed":
      return {
        t: "completed",
        result: {
          status: "completed",
          command: input.request.command,
          snapshot: toWorkflowSnapshot({ state, journalPath: input.journalPath }),
          budgetPlan: input.read.opened.budgetPlan,
          journalPath: input.journalPath,
          scriptPath: input.read.opened.scriptPath,
        },
      }
    case "queued":
    case "running":
      return { t: "resume", replay: buildWorkflowReplayPlan({ read: input.read, mutationFiles: input.mutationFiles }) }
  }
}

export function prepareWorkflowResumeRun(input: {
  readonly read: JournalReadResult
  readonly journalPath: string
  readonly scriptSha256: string
  readonly provider: PreparedWorkflowRun["provider"]
}): PreparedWorkflowRun {
  return {
    command: "resume",
    runId: input.read.opened.runId,
    workflowName: input.read.opened.workflowName,
    scriptPath: input.read.opened.scriptPath,
    scriptSha256: input.scriptSha256,
    journalPath: input.journalPath,
    args: input.read.opened.args,
    provider: input.provider,
    budgetPlan: input.read.opened.budgetPlan,
    limits: input.read.opened.limits,
    runtimeContract: input.read.opened.runtimeContract,
    requestedRunId: { t: "requested", value: input.read.opened.runId },
  }
}

export function buildWorkflowReplayPlan(input: { readonly read: JournalReadResult; readonly mutationFiles: readonly string[] }): WorkflowReplayPlan {
  const completedAgents = new Map<string, Extract<JournalReadResult["events"][number], { readonly t: "agent_completed" }>>()
  const resumableAgents = new Map<string, Extract<JournalReadResult["events"][number], { readonly t: "agent_started" }>>()
  const phaseLogEvents: Extract<JournalReadResult["events"][number], { readonly t: "phase_entered" | "log_emitted" }>[] = []
  let observedTokens = 0
  let observedToolCalls = 0
  for (const event of input.read.events) {
    switch (event.t) {
      case "agent_completed":
        completedAgents.set(event.node, event)
        resumableAgents.delete(event.node)
        observedTokens += event.tokens
        observedToolCalls += event.toolCalls
        break
      case "agent_started":
        resumableAgents.set(event.node, event)
        break
      case "agent_failed":
        resumableAgents.delete(event.node)
        observedTokens += event.tokens === undefined ? 0 : event.tokens
        observedToolCalls += event.toolCalls === undefined ? 0 : event.toolCalls
        break
      case "phase_entered":
      case "log_emitted":
        phaseLogEvents.push(event)
        break
      case "run_opened":
      case "runner_attached":
      case "runner_heartbeat":
      case "runner_detached":
      case "agent_scheduled":
      case "agent_progress":
      case "agent_retried":
      case "agent_replayed":
      case "child_started":
      case "child_finished":
      case "script_changed":
      case "run_finished":
        break
    }
  }
  return { t: "resume", live: false, mutationFiles: input.mutationFiles, phaseLogCursor: 0, phaseLogEvents, completedAgents, resumableAgents, observedTokens, observedToolCalls }
}

export function hasRunnerAttached(input: { readonly read: JournalReadResult; readonly pid: number }): boolean {
  for (const event of input.read.events) {
    if (event.t === "runner_attached" && event.pid === input.pid) return true
  }
  return false
}
