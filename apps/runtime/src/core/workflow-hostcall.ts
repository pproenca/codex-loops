import type {
  ApprovalPosture,
  HostAgentCall,
  HostLogCall,
  HostParallelCall,
  HostPhaseCall,
  HostPipelineCall,
  HostWorkflowCall,
  JournalEvent,
  JournalEventDraft,
  WorkflowChildPlan,
  WorkflowLimits,
  WorkflowReplayPlan,
  WorkflowTerminalStatus,
} from "../domain/contracts.ts"
import type { JsonValue } from "../domain/json.ts"

export type WorkflowHostState = {
  readonly runId: string
  readonly phaseTitles: readonly string[]
  readonly currentPhase:
    | { readonly t: "none" }
    | { readonly t: "selected"; readonly index: number; readonly title: string }
  readonly agentOrdinal: number
  readonly childOrdinal: number
  readonly depth: number
  readonly mutationFiles: readonly string[]
  readonly limits: WorkflowLimits
  readonly approval: ApprovalPosture
  readonly replay: WorkflowReplayPlan
  readonly observedTokens: number
  readonly observedToolCalls: number
}

export type WorkflowHostDecision =
  | {
    readonly t: "accepted"
    readonly state: WorkflowHostState
    readonly events: readonly JournalEventDraft[]
    readonly value: JsonValue
  }
  | {
    readonly t: "rejected"
    readonly state: WorkflowHostState
    readonly events: readonly JournalEventDraft[]
    readonly error: string
  }

export type AgentTurnPlan = {
  readonly node: string
  readonly attempt: number
  readonly label: string
  readonly prompt: string
  readonly schema?: JsonValue | undefined
  readonly model?: string | undefined
  readonly effort: "medium" | "high" | "xhigh"
  readonly isolation?: "read-only" | "workspace-write" | "worktree" | "full-access" | undefined
  readonly threadId?: string | undefined
}

export type ProviderAgentHostDecision =
  | {
    readonly t: "accepted"
    readonly state: WorkflowHostState
    readonly events: readonly JournalEventDraft[]
    readonly plan: AgentTurnPlan
  }
  | {
    readonly t: "replayed"
    readonly state: WorkflowHostState
    readonly events: readonly JournalEventDraft[]
    readonly value: JsonValue
  }
  | {
    readonly t: "rejected"
    readonly state: WorkflowHostState
    readonly events: readonly JournalEventDraft[]
    readonly error: string
  }

export type WorkflowChildHostDecision =
  | {
    readonly t: "accepted"
    readonly state: WorkflowHostState
    readonly events: readonly JournalEventDraft[]
    readonly plan: WorkflowChildPlan
  }
  | {
    readonly t: "rejected"
    readonly state: WorkflowHostState
    readonly events: readonly JournalEventDraft[]
    readonly error: string
  }

export type ProviderMutationDecision =
  | { readonly t: "accepted"; readonly state: WorkflowHostState }
  | { readonly t: "rejected"; readonly state: WorkflowHostState; readonly error: string }

export function initialWorkflowHostState(input: {
  readonly runId: string
  readonly limits: WorkflowLimits
  readonly approval: ApprovalPosture
  readonly replay: WorkflowReplayPlan
}): WorkflowHostState {
  return {
    runId: input.runId,
    phaseTitles: [],
    currentPhase: { t: "none" },
    agentOrdinal: 0,
    childOrdinal: 0,
    depth: 0,
    mutationFiles: input.replay.t === "fresh" ? [] : input.replay.mutationFiles,
    limits: input.limits,
    approval: input.approval,
    replay: input.replay,
    observedTokens: observedTokensForReplay(input.replay),
    observedToolCalls: observedToolCallsForReplay(input.replay),
  }
}

export function budgetSnapshot(state: WorkflowHostState): { readonly total: number | null; readonly spent: number; readonly remaining: number | null } {
  const total = state.limits.taskBudgetTokens
  return {
    total: total === undefined ? null : total,
    spent: state.observedTokens,
    remaining: total === undefined ? null : Math.max(0, total - state.observedTokens),
  }
}

export function applyObservedUsage(state: WorkflowHostState, events: readonly JournalEventDraft[]): WorkflowHostState {
  const tokens = events.reduce((sum, event) => sum + observedTokensForEvent(event), 0)
  const toolCalls = events.reduce((sum, event) => sum + observedToolCallsForEvent(event), 0)
  if (tokens === 0 && toolCalls === 0) return state
  return {
    ...state,
    observedTokens: state.observedTokens + tokens,
    observedToolCalls: state.observedToolCalls + toolCalls,
  }
}

export function applyPhaseHostcall(state: WorkflowHostState, call: HostPhaseCall): WorkflowHostDecision {
  const existingIndex = state.phaseTitles.indexOf(call.title)
  const index = existingIndex >= 0 ? existingIndex : state.phaseTitles.length
  const phaseTitles = existingIndex >= 0 ? state.phaseTitles : [...state.phaseTitles, call.title]
  const replay = matchPhaseReplay(state.replay, call.title)
  const currentPhase: WorkflowHostState["currentPhase"] = { t: "selected", index, title: call.title }
  const nextState = {
    ...state,
    replay: replay.replay,
    phaseTitles,
    currentPhase,
  }
  switch (replay.t) {
    case "matched":
      return {
        t: "accepted",
        state: nextState,
        events: [],
        value: null,
      }
    case "live":
      return {
        t: "accepted",
        state: nextState,
        events: [{ t: "phase_entered", phase: index, title: call.title }],
        value: null,
      }
  }
}

export function applyLogHostcall(state: WorkflowHostState, call: HostLogCall): WorkflowHostDecision {
  const replay = matchLogReplay(state.replay, call.message)
  return {
    t: "accepted",
    state: { ...state, replay: replay.replay },
    events: replay.t === "matched" ? [] : [{ t: "log_emitted", message: call.message }],
    value: null,
  }
}

export function applyAgentHostcall(state: WorkflowHostState, call: HostAgentCall): WorkflowHostDecision {
  const budgetCap = budgetSchedulingError(state)
  if (budgetCap !== undefined) return reject(state, budgetCap)
  const mutationCap = existingMutationCapError(state)
  if (mutationCap !== undefined) return reject(state, mutationCap)
  if (state.agentOrdinal >= state.limits.maxAgents) {
    return reject(state, `agent() exceeded maxAgents ${state.limits.maxAgents}`)
  }
  if (call.prompt.length > state.limits.maxPromptBytesPerAgent) {
    return reject(state, `agent() prompt exceeded maxPromptBytesPerAgent ${state.limits.maxPromptBytesPerAgent}`)
  }
  if (call.options.isolation === "full-access" && state.approval !== "approved") {
    return reject(state, "agent() full-access isolation requires explicit approval")
  }
  const label = call.options.label === undefined ? `agent-${state.agentOrdinal + 1}` : call.options.label
  const promptHash = stableHash32(call.prompt)
  const optionsHash = stableHash32(jsonText(call.options))
  const schemaHash = call.options.schema === undefined ? undefined : stableHash32(jsonText(call.options.schema))
  const phase = phaseFor(state, call)
  const node = stableHash32(`${state.runId}\n${phase.titleForNode}\n${label}\n${promptHash}\n${schemaHash === undefined ? "" : schemaHash}\n${optionsHash}`)
  const result = mockAgentResult(label, call.prompt)
  const tokens = Math.max(1, Math.ceil(call.prompt.length / 4))
  const scheduled: JournalEventDraft = {
    t: "agent_scheduled",
    node,
    label,
    attempt: 1,
    promptHash,
    optionsHash,
    promptPreview: preview(call.prompt, 180),
    promptFull: call.prompt,
    effort: "high",
    routeReason: "modelPolicy.defaultEffort",
    ...(schemaHash === undefined ? {} : { schemaHash }),
    ...(phase.phaseIndex === undefined ? {} : { phase: phase.phaseIndex }),
    ...(phase.phaseTitle === undefined ? {} : { phaseTitle: phase.phaseTitle }),
    ...(call.options.model === undefined ? {} : { model: call.options.model }),
    ...(call.options.agentType === undefined ? {} : { agentType: call.options.agentType }),
    ...(call.options.isolation === undefined ? {} : { isolation: call.options.isolation }),
    ...(call.options.risk === undefined ? {} : { risk: call.options.risk }),
  }
  const cached = completedAgentFor(state.replay, node)
  if (cached !== undefined) {
    return {
      t: "accepted",
      state: advanceAgentState(state, false),
      events: [{ t: "agent_replayed", node, attempt: cached.attempt }],
      value: cached.result,
    }
  }
  return {
    t: "accepted",
    state: advanceAgentState(state, true),
    events: [
      scheduled,
      { t: "agent_started", node, attempt: 1 },
      {
        t: "agent_completed",
        node,
        attempt: 1,
        threadId: `mock-${node}`,
        result,
        tokens,
        toolCalls: 0,
        durationMs: 0,
        source: "mock",
      },
    ],
    value: result,
  }
}

export function planProviderAgentHostcall(state: WorkflowHostState, call: HostAgentCall): ProviderAgentHostDecision {
  const budgetCap = budgetSchedulingError(state)
  if (budgetCap !== undefined) return rejectProvider(state, budgetCap)
  const mutationCap = existingMutationCapError(state)
  if (mutationCap !== undefined) return rejectProvider(state, mutationCap)
  if (state.agentOrdinal >= state.limits.maxAgents) {
    return rejectProvider(state, `agent() exceeded maxAgents ${state.limits.maxAgents}`)
  }
  if (call.prompt.length > state.limits.maxPromptBytesPerAgent) {
    return rejectProvider(state, `agent() prompt exceeded maxPromptBytesPerAgent ${state.limits.maxPromptBytesPerAgent}`)
  }
  if (call.options.isolation === "full-access" && state.approval !== "approved") {
    return rejectProvider(state, "agent() full-access isolation requires explicit approval")
  }
  const label = call.options.label === undefined ? `agent-${state.agentOrdinal + 1}` : call.options.label
  const promptHash = stableHash32(call.prompt)
  const optionsHash = stableHash32(jsonText(call.options))
  const schemaHash = call.options.schema === undefined ? undefined : stableHash32(jsonText(call.options.schema))
  const phase = phaseFor(state, call)
  const node = stableHash32(`${state.runId}\n${phase.titleForNode}\n${label}\n${promptHash}\n${schemaHash === undefined ? "" : schemaHash}\n${optionsHash}`)
  const effort = "high"
  const scheduled: JournalEventDraft = {
    t: "agent_scheduled",
    node,
    label,
    attempt: 1,
    promptHash,
    optionsHash,
    promptPreview: preview(call.prompt, 180),
    promptFull: call.prompt,
    effort,
    routeReason: "modelPolicy.defaultEffort",
    ...(schemaHash === undefined ? {} : { schemaHash }),
    ...(phase.phaseIndex === undefined ? {} : { phase: phase.phaseIndex }),
    ...(phase.phaseTitle === undefined ? {} : { phaseTitle: phase.phaseTitle }),
    ...(call.options.model === undefined ? {} : { model: call.options.model }),
    ...(call.options.agentType === undefined ? {} : { agentType: call.options.agentType }),
    ...(call.options.isolation === undefined ? {} : { isolation: call.options.isolation }),
    ...(call.options.risk === undefined ? {} : { risk: call.options.risk }),
  }
  const cached = completedAgentFor(state.replay, node)
  if (cached !== undefined) {
    return {
      t: "replayed",
      state: advanceAgentState(state, false),
      events: [{ t: "agent_replayed", node, attempt: cached.attempt }],
      value: cached.result,
    }
  }
  const resumable = resumableAgentFor(state.replay, node)
  if (resumable !== undefined && resumable.threadId !== undefined) {
    return {
      t: "accepted",
      state: advanceAgentState(state, true),
      events: [{ t: "agent_started", node, attempt: resumable.attempt, threadId: resumable.threadId }],
      plan: {
        node,
        attempt: resumable.attempt,
        label,
        prompt: call.prompt,
        effort,
        threadId: resumable.threadId,
        ...(call.options.schema === undefined ? {} : { schema: call.options.schema }),
        ...(call.options.model === undefined ? {} : { model: call.options.model }),
        ...(call.options.isolation === undefined ? {} : { isolation: call.options.isolation }),
      },
    }
  }
  if (resumable !== undefined) {
    return rejectProvider(state, "resume cannot safely restart provider turn without a recorded thread binding")
  }
  return {
    t: "accepted",
    state: advanceAgentState(state, true),
    events: [scheduled, { t: "agent_started", node, attempt: 1 }],
    plan: {
      node,
      attempt: 1,
      label,
      prompt: call.prompt,
      effort,
      ...(call.options.schema === undefined ? {} : { schema: call.options.schema }),
      ...(call.options.model === undefined ? {} : { model: call.options.model }),
      ...(call.options.isolation === undefined ? {} : { isolation: call.options.isolation }),
    },
  }
}

export function planWorkflowHostcall(state: WorkflowHostState, call: HostWorkflowCall): WorkflowChildHostDecision {
  if (state.depth >= 1) return rejectChild(state, "workflow() nesting is limited to one child level")
  const name = childName(call)
  const ordinal = state.childOrdinal + 1
  const plan: WorkflowChildPlan = { w: `${name}#${ordinal}`, name, ref: call.ref, args: call.args }
  return {
    t: "accepted",
    state: { ...state, childOrdinal: ordinal, depth: state.depth + 1 },
    events: [{ t: "child_started", w: plan.w, name }],
    plan,
  }
}

export function completeWorkflowHostcall(input: { readonly state: WorkflowHostState; readonly plan: WorkflowChildPlan; readonly status: WorkflowTerminalStatus; readonly result?: JsonValue | undefined }): WorkflowHostDecision {
  return {
    t: "accepted",
    state: { ...input.state, depth: input.state.depth - 1 },
    events: [{
      t: "child_finished",
      w: input.plan.w,
      status: input.status,
      ...(input.result === undefined ? {} : { result: input.result }),
    }],
    value: input.result === undefined ? null : input.result,
  }
}

export function applyProviderMutationFiles(state: WorkflowHostState, files: readonly string[]): ProviderMutationDecision {
  const mutationFiles = mergeMutationFiles(state.mutationFiles, files)
  if (mutationFiles.length > state.limits.maxMutationFilesPerRun) {
    return {
      t: "rejected",
      state: { ...state, mutationFiles },
      error: `agent file mutations exceeded maxMutationFilesPerRun ${state.limits.maxMutationFilesPerRun}`,
    }
  }
  return { t: "accepted", state: { ...state, mutationFiles } }
}

export function applyParallelHostcall(state: WorkflowHostState, call: HostParallelCall): WorkflowHostDecision {
  if (call.itemCount > state.limits.maxParallelItems) {
    return reject(state, `parallel() exceeded maxParallelItems ${state.limits.maxParallelItems}`)
  }
  return { t: "accepted", state, events: [], value: null }
}

export function applyPipelineHostcall(state: WorkflowHostState, call: HostPipelineCall): WorkflowHostDecision {
  if (call.itemCount > state.limits.maxPipelineItems) {
    return reject(state, `pipeline() exceeded maxPipelineItems ${state.limits.maxPipelineItems}`)
  }
  if (call.stageCount > state.limits.maxPipelineItems) {
    return reject(state, `pipeline() exceeded maxPipelineItems ${state.limits.maxPipelineItems}`)
  }
  return { t: "accepted", state, events: [], value: null }
}

function reject(state: WorkflowHostState, error: string): WorkflowHostDecision {
  return {
    t: "rejected",
    state,
    events: [],
    error,
  }
}

function rejectProvider(state: WorkflowHostState, error: string): ProviderAgentHostDecision {
  return {
    t: "rejected",
    state,
    events: [],
    error,
  }
}

function rejectChild(state: WorkflowHostState, error: string): WorkflowChildHostDecision {
  return {
    t: "rejected",
    state,
    events: [],
    error,
  }
}

function matchPhaseReplay(replay: WorkflowReplayPlan, title: string): { readonly t: "matched"; readonly replay: WorkflowReplayPlan } | { readonly t: "live"; readonly replay: WorkflowReplayPlan } {
  switch (replay.t) {
    case "fresh":
      return { t: "live", replay }
    case "resume":
      {
        if (replay.live) return { t: "live", replay }
        const next = replay.phaseLogEvents[replay.phaseLogCursor]
        if (next !== undefined && next.t === "phase_entered" && next.title === title) {
          return { t: "matched", replay: { ...replay, phaseLogCursor: replay.phaseLogCursor + 1 } }
        }
        return { t: "live", replay: { ...replay, live: true } }
      }
  }
}

function matchLogReplay(replay: WorkflowReplayPlan, message: string): { readonly t: "matched"; readonly replay: WorkflowReplayPlan } | { readonly t: "live"; readonly replay: WorkflowReplayPlan } {
  switch (replay.t) {
    case "fresh":
      return { t: "live", replay }
    case "resume":
      {
        if (replay.live) return { t: "live", replay }
        const next = replay.phaseLogEvents[replay.phaseLogCursor]
        if (next !== undefined && next.t === "log_emitted" && next.message === message) {
          return { t: "matched", replay: { ...replay, phaseLogCursor: replay.phaseLogCursor + 1 } }
        }
        return { t: "live", replay: { ...replay, live: true } }
      }
  }
}

function completedAgentFor(replay: WorkflowReplayPlan, node: string): Extract<JournalEvent, { readonly t: "agent_completed" }> | undefined {
  switch (replay.t) {
    case "fresh":
      return undefined
    case "resume":
      return replay.completedAgents.get(node)
  }
}

function resumableAgentFor(replay: WorkflowReplayPlan, node: string): Extract<JournalEvent, { readonly t: "agent_started" }> | undefined {
  switch (replay.t) {
    case "fresh":
      return undefined
    case "resume":
      return replay.resumableAgents.get(node)
  }
}

function advanceAgentState(state: WorkflowHostState, liveMiss: boolean): WorkflowHostState {
  return { ...state, agentOrdinal: state.agentOrdinal + 1, replay: liveMiss ? markReplayLive(state.replay) : state.replay }
}

function markReplayLive(replay: WorkflowReplayPlan): WorkflowReplayPlan {
  switch (replay.t) {
    case "fresh":
      return replay
    case "resume":
      return { ...replay, live: true }
  }
}

function observedTokensForReplay(replay: WorkflowReplayPlan): number {
  switch (replay.t) {
    case "fresh":
      return 0
    case "resume":
      return replay.observedTokens
  }
}

function observedToolCallsForReplay(replay: WorkflowReplayPlan): number {
  switch (replay.t) {
    case "fresh":
      return 0
    case "resume":
      return replay.observedToolCalls
  }
}

function observedTokensForEvent(event: JournalEventDraft): number {
  switch (event.t) {
    case "agent_progress":
    case "agent_completed":
    case "agent_failed":
      return event.tokens === undefined ? 0 : event.tokens
    case "run_opened":
    case "runner_attached":
    case "runner_heartbeat":
    case "phase_entered":
    case "log_emitted":
    case "agent_scheduled":
    case "agent_started":
    case "agent_retried":
    case "agent_replayed":
    case "child_started":
    case "child_finished":
    case "script_changed":
    case "run_finished":
      return 0
  }
}

function observedToolCallsForEvent(event: JournalEventDraft): number {
  switch (event.t) {
    case "agent_progress":
    case "agent_completed":
    case "agent_failed":
      return event.toolCalls === undefined ? 0 : event.toolCalls
    case "run_opened":
    case "runner_attached":
    case "runner_heartbeat":
    case "phase_entered":
    case "log_emitted":
    case "agent_scheduled":
    case "agent_started":
    case "agent_retried":
    case "agent_replayed":
    case "child_started":
    case "child_finished":
    case "script_changed":
    case "run_finished":
      return 0
  }
}

function budgetSchedulingError(state: WorkflowHostState): string | undefined {
  const total = state.limits.taskBudgetTokens
  if (total === undefined) return undefined
  if (state.observedTokens >= total) {
    return `workflow token budget exceeded (${formatCount(state.observedTokens)} / ${formatCount(total)} tokens). Stopping further agent() calls. In-flight agents will complete; their results are preserved.`
  }
  const minRemaining = state.limits.minRemainingTokensForAgent
  if (minRemaining === undefined) return undefined
  const remaining = total - state.observedTokens
  if (remaining < minRemaining) {
    return `workflow token budget remaining below minRemainingTokensForAgent (${formatCount(remaining)} / ${formatCount(minRemaining)} tokens). Stopping further agent() calls. In-flight agents will complete; their results are preserved.`
  }
  return undefined
}

function formatCount(value: number): string {
  return new Intl.NumberFormat("en-US").format(value)
}

function childName(call: HostWorkflowCall): string {
  switch (call.ref.t) {
    case "named":
      return call.ref.value
    case "script_path":
      return leafName(call.ref.scriptPath)
  }
}

function leafName(path: string): string {
  const normalized = path.replaceAll("\\", "/")
  const parts = normalized.split("/")
  const last = parts[parts.length - 1]
  return last === undefined || last.length === 0 ? normalized : last
}

function mergeMutationFiles(previous: readonly string[], next: readonly string[]): readonly string[] {
  const merged = [...previous]
  for (const path of next) {
    if (!merged.includes(path)) merged.push(path)
  }
  return merged
}

function existingMutationCapError(state: WorkflowHostState): string | undefined {
  if (state.mutationFiles.length <= state.limits.maxMutationFilesPerRun) return undefined
  return `agent file mutations exceeded maxMutationFilesPerRun ${state.limits.maxMutationFilesPerRun}`
}

function phaseFor(state: WorkflowHostState, call: HostAgentCall): {
  readonly phaseIndex?: number | undefined
  readonly phaseTitle?: string | undefined
  readonly titleForNode: string
} {
  if (call.options.phase !== undefined) return { phaseTitle: call.options.phase, titleForNode: call.options.phase }
  switch (state.currentPhase.t) {
    case "none":
      return { titleForNode: "" }
    case "selected":
      return { phaseIndex: state.currentPhase.index, phaseTitle: state.currentPhase.title, titleForNode: state.currentPhase.title }
  }
}

function mockAgentResult(label: string, prompt: string): JsonValue {
  return {
    label,
    summary: "Mock workflow result.",
    prompt,
  }
}

function jsonText(value: JsonValue | HostAgentCall["options"]): string {
  const text = JSON.stringify(value)
  return text === undefined ? "undefined" : text
}

function preview(value: string, maxLength: number): string {
  return value.length <= maxLength ? value : `${value.slice(0, maxLength - 3)}...`
}

function stableHash32(value: string): string {
  let hash = 2166136261
  for (let index = 0; index < value.length; index += 1) {
    hash ^= value.charCodeAt(index)
    hash = Math.imul(hash, 16777619)
  }
  const part = (hash >>> 0).toString(16).padStart(8, "0")
  return `${part}${part}${part}${part}`
}
