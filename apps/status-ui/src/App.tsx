import { useQuery, type UseQueryResult } from "@tanstack/react-query"
import { Link, useNavigate } from "@tanstack/react-router"
import { useEffect } from "react"

import { statusStreamErrorQueryKey } from "./statusClient"
import type { StatusNode, StatusPayload, StatusPhase } from "./statusSchema"

type StatusAppProps = {
  readonly payload: StatusPayload | undefined
  readonly phaseIndex: number
  readonly agentId?: string | undefined
  readonly query: UseQueryResult<StatusPayload, Error>
}

export function StatusApp({ payload, phaseIndex, agentId, query }: StatusAppProps) {
  const navigate = useNavigate()
  const streamError = useQuery<string | null>({ queryKey: statusStreamErrorQueryKey, enabled: false })
  const phases = payload?.status.phases ?? []
  const selectedPhaseIndex = clampIndex(phaseIndex, phases.length)
  const selectedPhase = phases[selectedPhaseIndex]

  useEffect(() => {
    if (phases.length > 0 && selectedPhaseIndex !== phaseIndex) {
      void navigate({ to: "/phase/$phaseIndex", params: { phaseIndex: String(selectedPhaseIndex) }, replace: true })
    }
  }, [navigate, phaseIndex, phases.length, selectedPhaseIndex])

  return (
    <div className="shell">
      <header className="topbar">
        <div className="title-group">
          <p className="eyebrow">Codex Loops</p>
          <h1>{payload?.status.workflowName ?? "Workflow status"}</h1>
          <p className="journal">{payload?.databasePath ?? "Loading run storage..."}</p>
        </div>
        <div className="run-meta">
          <span className={`pill ${statusClass(payload?.status.status)}`}>{payload?.status.status ?? "loading"}</span>
          <span className="pill neutral">Run {payload?.status.runId ?? "-"}</span>
        </div>
      </header>

      {query.error ? <div className="banner error">{query.error.message}</div> : null}
      {streamError.data ? <div className="banner warning">{streamError.data}</div> : null}

      <main className="layout">
        <aside className="phase-panel">
          <div className="panel-header">
            <h2>Phases</h2>
            <span>{phases.length} phases</span>
          </div>
          <nav aria-label="Workflow phases" className="phase-list">
            {phases.length === 0 ? <p className="empty">No phases recorded yet.</p> : phases.map((phase, index) => (
              <PhaseLink key={`${phase.title ?? "phase"}-${index}`} phase={phase} index={index} selected={index === selectedPhaseIndex} />
            ))}
          </nav>
        </aside>

        <section className="detail-panel" aria-live="polite">
          <div className="panel-header">
            <div>
              <p className="eyebrow">Selected phase</p>
              <h2>{selectedPhase?.title ?? "No phase selected"}</h2>
            </div>
            {selectedPhase ? <span className={`pill ${statusClass(selectedPhase.status)}`}>{selectedPhase.status ?? "pending"}</span> : null}
          </div>
          <div className="agent-list">
            {selectedPhase === undefined ? <p className="empty">Waiting for phase data.</p> : selectedPhase.nodes.length === 0 ? <p className="empty">No agents in this phase.</p> : selectedPhase.nodes.map((node, index) => {
              const nodeKey = node.id ?? node.label ?? String(index)
              return <AgentRow key={nodeKey} node={node} phaseIndex={selectedPhaseIndex} selected={agentId === nodeKey} routeId={nodeKey} />
            })}
          </div>
        </section>
      </main>

      <details className="raw-payload">
        <summary>Raw status payload</summary>
        <pre>{payload ? JSON.stringify(payload, null, 2) : "Loading..."}</pre>
      </details>
    </div>
  )
}

function PhaseLink({ phase, index, selected }: { readonly phase: StatusPhase; readonly index: number; readonly selected: boolean }) {
  const progress = phaseProgress(phase)
  return (
    <Link to="/phase/$phaseIndex" params={{ phaseIndex: String(index) }} className={`phase-link ${selected ? "selected" : ""}`}>
      <span className="icon" aria-hidden="true">{progress.done >= progress.total ? "[x]" : "[ ]"}</span>
      <span className="phase-title">{phase.title ?? `Phase ${index + 1}`}</span>
      <span className="progress" aria-label={`${progress.done} of ${progress.total} complete`}>{progress.done}/{progress.total}</span>
    </Link>
  )
}

function AgentRow({ node, phaseIndex, selected, routeId }: { readonly node: StatusNode; readonly phaseIndex: number; readonly selected: boolean; readonly routeId: string }) {
  return (
    <article className={`agent-row ${selected ? "selected" : ""}`}>
      <Link to="/phase/$phaseIndex/agent/$agentId" params={{ phaseIndex: String(phaseIndex), agentId: routeId }} className="agent-summary">
        <span className={`icon ${statusClass(node.state)}`} aria-label={node.state ?? "queued"}>{statusIcon(node.state)}</span>
        <span className="agent-name">{node.label ?? node.id ?? "Agent"}</span>
        <span className="meta">{node.model ?? "model n/a"}</span>
        <span className="meta">{formatNumber(node.tokens)} tokens</span>
        <span className="meta">{formatNumber(node.toolCalls)} tools</span>
      </Link>
      {selected ? (
        <div className="agent-detail">
          <InfoSection title="Goal">{node.promptFull ?? node.promptPreview ?? "No goal recorded."}</InfoSection>
          <InfoSection title="Last tool calls">{node.lastToolSummary ?? "No tool calls recorded."}</InfoSection>
          <InfoSection title="Outcome">{outcomeText(node)}</InfoSection>
        </div>
      ) : null}
    </article>
  )
}

function InfoSection({ title, children }: { readonly title: string; readonly children: string }) {
  return (
    <section className="info-section">
      <h3>{title}</h3>
      <p>{children}</p>
    </section>
  )
}

function phaseProgress(phase: StatusPhase): { readonly done: number; readonly total: number } {
  const total = Math.max(phase.nodes.length, 1)
  const done = phase.nodes.filter((node) => {
    const state = (node.state ?? "").toLowerCase()
    return state === "done" || state === "completed"
  }).length
  return { done, total }
}

function clampIndex(index: number, length: number): number {
  if (length <= 0) return 0
  if (!Number.isFinite(index) || index < 0) return 0
  return Math.min(index, length - 1)
}

function statusIcon(value: string | undefined): string {
  const state = (value ?? "queued").toLowerCase()
  if (state === "done" || state === "completed") return "[x]"
  if (state === "failed" || state === "killed") return "[!]"
  if (state === "running") return "[~]"
  return "[ ]"
}

function statusClass(value: string | undefined): string {
  const state = (value ?? "pending").toLowerCase()
  if (state === "done" || state === "completed") return "success"
  if (state === "failed" || state === "killed") return "danger"
  if (state === "running") return "active"
  return "pending"
}

function formatNumber(value: number | undefined): string {
  return typeof value === "number" ? value.toLocaleString() : "0"
}

function outcomeText(node: StatusNode): string {
  if (node.error !== undefined) return compact(node.error, "Execution failed without an error message.")
  const result = node.result
  if (isRecord(result)) {
    if (typeof result.summary === "string" && result.summary !== "") return result.summary
    if (typeof result.passed === "boolean") return result.passed ? "Verification passed." : "Verification failed."
    if (typeof result.accepted === "boolean") return result.accepted ? "Review accepted." : "Review rejected."
    if (typeof result.ok === "boolean") return result.ok ? "Completed successfully." : "Completed with issues."
    if (typeof result.status === "string" && result.status !== "") return `Result status: ${result.status}.`
    if (Array.isArray(result.changedFiles)) return `Updated ${result.changedFiles.length.toLocaleString()} files.`
    return "Completed with structured output."
  }
  if (result !== undefined && result !== null) return compact(result, "Completed.")
  const state = (node.state ?? "").toLowerCase()
  if (state === "done" || state === "completed") return "Completed."
  if (state === "running") return "Still running."
  if (state === "queued") return "Queued."
  if (state === "failed" || state === "killed") return "Stopped before returning an outcome."
  return "No outcome yet."
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value)
}

function compact(value: unknown, fallback: string): string {
  if (value === undefined || value === null || value === "") return fallback
  const text = typeof value === "string" ? value : JSON.stringify(value)
  return text.length > 320 ? `${text.slice(0, 317)}...` : text
}
