import { foldJournal, toWorkflowStatusSummary } from "./journal-projection.ts"
import type { JournalReadResult } from "../domain/contracts.ts"

export type ServeStatusPayload = {
  readonly compactPayload: string
  readonly prettyPayload: string
}

export function buildServeStatusPayload(input: {
  readonly read: JournalReadResult
  readonly databasePath: string
  readonly eventLimit: number
  readonly agentGoals?: Readonly<Record<string, string>> | undefined
}): ServeStatusPayload {
  const state = foldJournal(input.read)
  const status = toWorkflowStatusSummary({ state, databasePath: input.databasePath, tailEvents: input.read.events, eventLimit: input.eventLimit })
  const payload = { runId: state.runId, databasePath: input.databasePath, status: enrichAgentGoals(status, input.agentGoals) }
  return {
    compactPayload: JSON.stringify(payload),
    prettyPayload: JSON.stringify(payload, null, 2),
  }
}

export function extractStaticAgentGoals(source: string): Readonly<Record<string, string>> {
  const goals: Record<string, string> = {}
  const pattern = /agent\s*\(\s*`([\s\S]*?)`\s*,\s*\{[\s\S]*?label\s*:\s*["']([^"']+)["']/g
  let match: RegExpExecArray | null
  while ((match = pattern.exec(source)) !== null) {
    const prompt = match[1]
    const label = match[2]
    if (prompt !== undefined && label !== undefined) goals[label] = prompt
  }
  return goals
}

function enrichAgentGoals(status: ReturnType<typeof toWorkflowStatusSummary>, goals: Readonly<Record<string, string>> | undefined): ReturnType<typeof toWorkflowStatusSummary> {
  if (goals === undefined || Object.keys(goals).length === 0) return status
  return {
    ...status,
    phases: status.phases.map((phase) => ({
      ...phase,
      nodes: phase.nodes.map((node) => {
        const promptFull = node.promptFull || goals[node.label]
        return promptFull === undefined ? node : { ...node, promptFull }
      }),
    })),
  }
}
