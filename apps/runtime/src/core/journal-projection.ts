import type {
  AgentNodeProjection,
  AgentNodeState,
  JournalEvent,
  RunProjectionState,
  WorkflowPhaseProjection,
  WorkflowPhaseStatus,
  WorkflowRunStatus,
  WorkflowSnapshot,
  WorkflowStatusSummary,
} from "../domain/contracts.ts"

type NodeCounts = Readonly<Record<AgentNodeState, number>>
type NodePatch = {
  readonly state?: AgentNodeState | undefined
  readonly attempt?: number | undefined
  readonly threadId?: string | undefined
  readonly result?: AgentNodeProjection["result"] | undefined
  readonly error?: string | undefined
  readonly tokens?: number | undefined
  readonly toolCalls?: number | undefined
  readonly durationMs?: number | undefined
  readonly lastToolName?: string | undefined
  readonly lastToolSummary?: string | undefined
}

export type FoldJournalInput = {
  readonly events: readonly JournalEvent[]
  readonly truncatedTail: boolean
}

export function foldJournal(input: FoldJournalInput): RunProjectionState {
  let state = initialState()
  for (const event of input.events) state = applyJournalEvent({ state, event })
  if (input.truncatedTail) state = { ...state, truncatedTail: true }
  return state
}

export function applyJournalEvent(input: { readonly state: RunProjectionState; readonly event: JournalEvent }): RunProjectionState {
  const state = { ...input.state, lastSeq: input.event.seq }
  switch (input.event.t) {
    case "run_opened":
      return {
        ...state,
        runId: input.event.runId,
        workflowName: input.event.workflowName,
        scriptPath: input.event.scriptPath,
        scriptSha256: input.event.scriptSha256,
        args: input.event.args,
        provider: input.event.provider,
        budgetPlan: input.event.budgetPlan,
        limits: input.event.limits,
        runtimeContract: input.event.runtimeContract,
        status: "queued",
      }
    case "runner_attached":
      return {
        ...state,
        status: "running",
        runner: { pid: input.event.pid, startedAt: input.event.startedAt, lastHeartbeatTs: input.event.ts },
      }
    case "runner_heartbeat":
      return heartbeat({ state, event: input.event })
    case "runner_detached":
      return { ...state, runner: undefined }
    case "phase_entered":
      return withPhase({ state, index: input.event.phase, title: input.event.title })
    case "log_emitted":
      return { ...state, logs: [...state.logs, input.event.message] }
    case "agent_scheduled":
      return withScheduledAgent({ state, event: input.event })
    case "agent_started":
      return updateNode({ state, id: input.event.node, update: { state: "running", attempt: input.event.attempt, threadId: input.event.threadId } })
    case "agent_progress":
      return updateNode({ state, id: input.event.node, update: progressUpdate(input.event) })
    case "agent_retried":
      return retryNode({ state, id: input.event.node, attempt: input.event.attempt })
    case "agent_completed":
      return completeNode({ state, event: input.event })
    case "agent_failed":
      return failNode({ state, event: input.event })
    case "agent_replayed":
    case "child_started":
    case "child_finished":
      return state
    case "script_changed":
      return { ...state, scriptSha256: input.event.scriptSha256 }
    case "run_finished":
      return finishRun({ state, event: input.event })
  }
}

export function toWorkflowSnapshot(input: { readonly state: RunProjectionState; readonly journalPath: string }): WorkflowSnapshot {
  return {
    schemaVersion: "workflow-snapshot/v2",
    runId: input.state.runId,
    workflowName: input.state.workflowName,
    status: input.state.status,
    runner: input.state.runner,
    scriptPath: input.state.scriptPath,
    scriptSha256: input.state.scriptSha256,
    journalPath: input.journalPath,
    args: input.state.args,
    phases: phaseSnapshots(input.state),
    logs: input.state.logs,
    result: input.state.result,
    error: input.state.error,
    agentCount: input.state.totals.agentCount,
    totalTokens: input.state.totals.totalTokens,
    totalToolCalls: input.state.totals.totalToolCalls,
    durationMs: input.state.durationMs,
    budgetPlan: input.state.budgetPlan,
    limits: input.state.limits,
    runtimeContract: input.state.runtimeContract,
    truncatedTail: input.state.truncatedTail,
  }
}

export function toWorkflowStatusSummary(input: {
  readonly state: RunProjectionState
  readonly tailEvents: readonly JournalEvent[]
  readonly eventLimit: number
}): WorkflowStatusSummary {
  const phases = phaseSnapshots(input.state)
  return {
    runId: input.state.runId,
    workflowName: input.state.workflowName,
    status: input.state.status,
    scriptPath: input.state.scriptPath,
    phaseCount: input.state.phases.length,
    phases,
    nodeCounts: countNodeStates(input.state.nodes),
    agentCount: input.state.totals.agentCount,
    totalTokens: input.state.totals.totalTokens,
    totalToolCalls: input.state.totals.totalToolCalls,
    durationMs: input.state.durationMs,
    runner: input.state.runner,
    budgetPlan: input.state.budgetPlan,
    runtimeContract: input.state.runtimeContract,
    result: input.state.result,
    error: input.state.error,
    lastEvents: input.eventLimit > 0 ? input.tailEvents.slice(-input.eventLimit) : [],
    truncatedTail: input.state.truncatedTail,
  }
}

function initialState(): RunProjectionState {
  return {
    runId: "",
    workflowName: "",
    scriptPath: "",
    scriptSha256: "",
    args: {},
    provider: "sdk",
    status: "queued",
    phases: [],
    nodes: new Map(),
    logs: [],
    totals: { agentCount: 0, totalTokens: 0, totalToolCalls: 0 },
    lastSeq: 0,
  }
}

function heartbeat(input: { readonly state: RunProjectionState; readonly event: Extract<JournalEvent, { readonly t: "runner_heartbeat" }> }): RunProjectionState {
  const runner = input.state.runner
  if (runner === undefined || runner.pid !== input.event.pid || input.event.ts === undefined) return input.state
  return { ...input.state, runner: { ...runner, lastHeartbeatTs: input.event.ts } }
}

function withPhase(input: { readonly state: RunProjectionState; readonly index: number; readonly title: string }): RunProjectionState {
  if (input.state.phases.some((phase) => phase.title === input.title)) return input.state
  const phase: RunProjectionState["phases"][number] = { index: input.index, title: input.title, status: "pending", nodeIds: [] }
  const phases = [...input.state.phases, phase]
  return { ...input.state, phases }
}

function withScheduledAgent(input: { readonly state: RunProjectionState; readonly event: Extract<JournalEvent, { readonly t: "agent_scheduled" }> }): RunProjectionState {
  const existing = input.state.nodes.get(input.event.node)
  const node: AgentNodeProjection = {
    id: input.event.node,
    label: input.event.label,
    phase: input.event.phase,
    phaseTitle: input.event.phaseTitle,
    state: "queued",
    attempt: input.event.attempt,
    promptHash: input.event.promptHash,
    schemaHash: input.event.schemaHash,
    optionsHash: input.event.optionsHash,
    promptPreview: input.event.promptPreview,
    promptFull: input.event.promptFull,
    model: input.event.model,
    effort: input.event.effort,
    routeReason: input.event.routeReason,
    agentType: input.event.agentType,
    agentDefinitionSha: input.event.agentDefinitionSha,
    isolation: input.event.isolation,
    risk: input.event.risk,
    threadId: existing?.threadId,
    result: existing?.result,
    error: undefined,
    tokens: existing === undefined ? 0 : existing.tokens,
    toolCalls: existing === undefined ? 0 : existing.toolCalls,
    durationMs: existing === undefined ? 0 : existing.durationMs,
  }
  const nodes = new Map(input.state.nodes)
  nodes.set(node.id, node)
  const phased = attachNodeToPhase({ phases: input.state.phases, node })
  return withTotals({ ...input.state, nodes, phases: phased })
}

function updateNode(input: { readonly state: RunProjectionState; readonly id: string; readonly update: NodePatch }): RunProjectionState {
  const existing = input.state.nodes.get(input.id)
  if (existing === undefined) return input.state
  const nodes = new Map(input.state.nodes)
  nodes.set(input.id, {
    ...existing,
    state: input.update.state === undefined ? existing.state : input.update.state,
    attempt: input.update.attempt === undefined ? existing.attempt : input.update.attempt,
    threadId: input.update.threadId === undefined ? existing.threadId : input.update.threadId,
    result: input.update.result === undefined ? existing.result : input.update.result,
    error: input.update.error === undefined ? existing.error : input.update.error,
    tokens: input.update.tokens === undefined ? existing.tokens : input.update.tokens,
    toolCalls: input.update.toolCalls === undefined ? existing.toolCalls : input.update.toolCalls,
    durationMs: input.update.durationMs === undefined ? existing.durationMs : input.update.durationMs,
    lastToolName: input.update.lastToolName === undefined ? existing.lastToolName : input.update.lastToolName,
    lastToolSummary: input.update.lastToolSummary === undefined ? existing.lastToolSummary : input.update.lastToolSummary,
  })
  return withTotals({ ...input.state, nodes })
}

function retryNode(input: { readonly state: RunProjectionState; readonly id: string; readonly attempt: number }): RunProjectionState {
  const existing = input.state.nodes.get(input.id)
  if (existing === undefined) return input.state
  return updateNode({ state: input.state, id: input.id, update: { attempt: Math.max(existing.attempt, input.attempt) } })
}

function progressUpdate(event: Extract<JournalEvent, { readonly t: "agent_progress" }>): NodePatch {
  return {
    tokens: event.tokens,
    toolCalls: event.toolCalls,
    lastToolName: event.lastToolName,
    lastToolSummary: event.lastToolSummary,
  }
}

function completeNode(input: { readonly state: RunProjectionState; readonly event: Extract<JournalEvent, { readonly t: "agent_completed" }> }): RunProjectionState {
  return updateNode({
    state: input.state,
    id: input.event.node,
    update: {
      state: "done",
      attempt: input.event.attempt,
      threadId: input.event.threadId,
      result: input.event.result,
      error: undefined,
      tokens: input.event.tokens,
      toolCalls: input.event.toolCalls,
      durationMs: input.event.durationMs,
    },
  })
}

function failNode(input: { readonly state: RunProjectionState; readonly event: Extract<JournalEvent, { readonly t: "agent_failed" }> }): RunProjectionState {
  return updateNode({
    state: input.state,
    id: input.event.node,
    update: {
      state: input.event.error.kind === "aborted" ? "killed" : "failed",
      attempt: input.event.attempt,
      error: input.event.error.message,
      tokens: input.event.tokens,
      toolCalls: input.event.toolCalls,
      durationMs: input.event.durationMs,
    },
  })
}

function finishRun(input: { readonly state: RunProjectionState; readonly event: Extract<JournalEvent, { readonly t: "run_finished" }> }): RunProjectionState {
  const nodes = input.event.status === "killed" ? killOpenNodes(input.state.nodes) : input.state.nodes
  return withTotals({
    ...input.state,
    status: input.event.status,
    result: input.event.result,
    error: input.event.error,
    durationMs: input.event.durationMs,
    nodes,
  })
}

function killOpenNodes(nodes: ReadonlyMap<string, AgentNodeProjection>): ReadonlyMap<string, AgentNodeProjection> {
  const next = new Map<string, AgentNodeProjection>()
  for (const [id, node] of nodes) {
    const state = node.state === "queued" || node.state === "running" ? "killed" : node.state
    next.set(id, { ...node, state })
  }
  return next
}

function attachNodeToPhase(input: {
  readonly phases: RunProjectionState["phases"]
  readonly node: AgentNodeProjection
}): RunProjectionState["phases"] {
  const phases = input.phases.map((phase) => ({ ...phase, nodeIds: [...phase.nodeIds] }))
  let index = input.node.phase
  if (index === undefined && input.node.phaseTitle !== undefined) {
    index = phases.find((phase) => phase.title === input.node.phaseTitle)?.index
  }
  if (index === undefined) return phases
  let phase = phases.find((entry) => entry.index === index)
  if (phase === undefined) {
    phase = { index, title: input.node.phaseTitle === undefined ? `phase ${index + 1}` : input.node.phaseTitle, status: "pending", nodeIds: [] }
    phases.push(phase)
  }
  if (!phase.nodeIds.includes(input.node.id)) phase.nodeIds.push(input.node.id)
  return recomputePhases({ phases, nodes: new Map([[input.node.id, input.node]]) })
}

function withTotals(state: RunProjectionState): RunProjectionState {
  let totalTokens = 0
  let totalToolCalls = 0
  for (const node of state.nodes.values()) {
    totalTokens += node.tokens
    totalToolCalls += node.toolCalls
  }
  return {
    ...state,
    totals: { agentCount: state.nodes.size, totalTokens, totalToolCalls },
    phases: recomputePhases({ phases: state.phases, nodes: state.nodes }),
  }
}

function recomputePhases(input: { readonly phases: RunProjectionState["phases"]; readonly nodes: ReadonlyMap<string, AgentNodeProjection> }): RunProjectionState["phases"] {
  return input.phases.map((phase) => {
    const nodes = phase.nodeIds.flatMap((id) => {
      const node = input.nodes.get(id)
      return node === undefined ? [] : [node]
    })
    return { ...phase, status: phaseStatus(nodes) }
  })
}

function phaseStatus(nodes: readonly AgentNodeProjection[]): WorkflowPhaseStatus {
  const counts = countNodeArray(nodes)
  if (counts.killed > 0) return "killed"
  if (counts.failed > 0) return "failed"
  if (counts.running > 0) return "running"
  if (counts.queued > 0) return "pending"
  if (nodes.length > 0 && counts.done === nodes.length) return "completed"
  return "pending"
}

function phaseSnapshots(state: RunProjectionState): readonly WorkflowPhaseProjection[] {
  const phased = new Set<string>()
  const snapshots = [...state.phases]
    .sort((a, b) => a.index - b.index)
    .map((phase) => {
      const nodes = phase.nodeIds.flatMap((id) => {
        const node = state.nodes.get(id)
        if (node === undefined) return []
        phased.add(id)
        return [node]
      })
      return { index: phase.index, title: phase.title, status: phase.status, nodes }
    })

  const unphased = [...state.nodes.values()].filter((node) => !phased.has(node.id))
  if (unphased.length > 0) {
    return [...snapshots, { index: -1, title: "(no phase)", status: phaseStatus(unphased), nodes: unphased }]
  }
  return snapshots
}

function countNodeStates(nodes: ReadonlyMap<string, AgentNodeProjection>): NodeCounts {
  return countNodeArray([...nodes.values()])
}

function countNodeArray(nodes: readonly AgentNodeProjection[]): NodeCounts {
  const counts = { queued: 0, running: 0, done: 0, failed: 0, killed: 0 }
  for (const node of nodes) counts[node.state] += 1
  return counts
}
