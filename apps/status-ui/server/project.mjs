export function buildStatusPayload(input) {
  const state = foldEvents(input.events)
  return {
    journalPath: input.journalPath,
    status: {
      runId: state.runId,
      workflowName: state.workflowName,
      status: state.status,
      scriptPath: state.scriptPath,
      phaseCount: state.phases.length,
      phases: phaseSnapshots(state),
      nodeCounts: countNodes([...state.nodes.values()]),
      agentCount: state.nodes.size,
      totalTokens: [...state.nodes.values()].reduce((total, node) => total + (node.tokens ?? 0), 0),
      totalToolCalls: [...state.nodes.values()].reduce((total, node) => total + (node.toolCalls ?? 0), 0),
      durationMs: state.durationMs,
      result: state.result,
      error: state.error,
      lastEvents: input.eventLimit > 0 ? input.events.slice(-input.eventLimit) : [],
      truncatedTail: false,
    },
  }
}

function foldEvents(events) {
  const state = { runId: "", workflowName: "", status: "queued", scriptPath: "", phases: [], nodes: new Map() }
  for (const event of events) applyEvent(state, event)
  return state
}

function applyEvent(state, event) {
  switch (event.t) {
    case "run_opened":
      state.runId = stringValue(event.runId)
      state.workflowName = stringValue(event.workflowName)
      state.scriptPath = stringValue(event.scriptPath)
      state.status = "queued"
      return
    case "runner_attached":
      state.status = "running"
      return
    case "phase_entered":
      addPhase(state, numberValue(event.phase, state.phases.length), stringValue(event.title) || `phase ${state.phases.length + 1}`)
      return
    case "agent_scheduled":
      scheduleAgent(state, event)
      return
    case "agent_started":
      updateAgent(state, event.node, { state: "running", attempt: event.attempt, threadId: event.threadId })
      return
    case "agent_progress":
      updateAgent(state, event.node, {
        tokens: event.tokens,
        toolCalls: event.toolCalls,
        lastToolName: event.lastToolName,
        lastToolSummary: event.lastToolSummary,
      })
      return
    case "agent_completed":
      updateAgent(state, event.node, {
        state: "done",
        attempt: event.attempt,
        threadId: event.threadId,
        result: event.result,
        error: undefined,
        tokens: event.tokens,
        toolCalls: event.toolCalls,
        durationMs: event.durationMs,
      })
      return
    case "agent_failed":
      updateAgent(state, event.node, {
        state: "failed",
        attempt: event.attempt,
        error: event.error ?? event.message,
        tokens: event.tokens,
        toolCalls: event.toolCalls,
        durationMs: event.durationMs,
      })
      return
    case "run_finished":
      state.status = event.status === "completed" ? "done" : stringValue(event.status) || "failed"
      state.result = event.result
      state.error = event.error
      state.durationMs = event.durationMs
      return
    default:
      return
  }
}

function addPhase(state, index, title) {
  if (state.phases.some((phase) => phase.index === index || phase.title === title)) return
  state.phases.push({ index, title, nodeIds: [] })
}

function scheduleAgent(state, event) {
  const id = stringValue(event.node)
  if (id === "") return
  const node = {
    id,
    label: stringValue(event.label) || id,
    phase: typeof event.phase === "number" ? event.phase : undefined,
    phaseTitle: typeof event.phaseTitle === "string" ? event.phaseTitle : undefined,
    state: "queued",
    attempt: event.attempt,
    promptPreview: event.promptPreview,
    promptFull: event.promptFull,
    model: event.model,
    effort: event.effort,
    isolation: event.isolation,
    risk: event.risk,
    tokens: 0,
    toolCalls: 0,
    durationMs: 0,
  }
  state.nodes.set(id, { ...state.nodes.get(id), ...node })
  attachNodeToPhase(state, node)
}

function updateAgent(state, nodeId, patch) {
  const id = stringValue(nodeId)
  if (id === "") return
  const current = state.nodes.get(id)
  if (current === undefined) return
  state.nodes.set(id, cleanUndefined({ ...current, ...patch }))
}

function attachNodeToPhase(state, node) {
  let phase = node.phase === undefined ? undefined : state.phases.find((entry) => entry.index === node.phase)
  if (phase === undefined && node.phaseTitle !== undefined) phase = state.phases.find((entry) => entry.title === node.phaseTitle)
  if (phase === undefined && node.phase !== undefined) {
    phase = { index: node.phase, title: node.phaseTitle ?? `phase ${node.phase + 1}`, nodeIds: [] }
    state.phases.push(phase)
  }
  if (phase !== undefined && !phase.nodeIds.includes(node.id)) phase.nodeIds.push(node.id)
}

function phaseSnapshots(state) {
  const phased = new Set()
  const snapshots = state.phases.map((phase) => {
    const nodes = phase.nodeIds.flatMap((id) => {
      const node = state.nodes.get(id)
      if (node === undefined) return []
      phased.add(id)
      return [node]
    })
    return { index: phase.index, title: phase.title, status: phaseStatus(nodes), nodes }
  })
  const unphased = [...state.nodes.values()].filter((node) => !phased.has(node.id))
  return unphased.length === 0 ? snapshots : [...snapshots, { index: -1, title: "(no phase)", status: phaseStatus(unphased), nodes: unphased }]
}

function phaseStatus(nodes) {
  const counts = countNodes(nodes)
  if (nodes.length === 0) return "pending"
  if (counts.failed > 0 || counts.killed > 0) return "failed"
  if (counts.running > 0) return "running"
  if (counts.done === nodes.length) return "completed"
  return "pending"
}

function countNodes(nodes) {
  const counts = { queued: 0, running: 0, done: 0, failed: 0, killed: 0 }
  for (const node of nodes) {
    const state = typeof node.state === "string" && node.state in counts ? node.state : "queued"
    counts[state] += 1
  }
  return counts
}

function stringValue(value) {
  return typeof value === "string" ? value : ""
}

function numberValue(value, fallback) {
  return typeof value === "number" && Number.isFinite(value) ? value : fallback
}

function cleanUndefined(value) {
  return Object.fromEntries(Object.entries(value).filter(([, entry]) => entry !== undefined))
}
