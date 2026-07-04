import { runWorkflowChildProcess } from "../containment/workflow-child-process.ts"
import { decideAgentProgress, initialAgentProgressSnapshot } from "../core/agent-progress.ts"
import { decideProviderTurnCompletion, decideStructuredOutputRetry, foldProviderTurnEvent, frameWorkflowWorkerPrompt, initialProviderTurnState } from "../core/provider-turn.ts"
import {
  applyAgentHostcall,
  applyObservedUsage,
  applyLogHostcall,
  applyParallelHostcall,
  applyPhaseHostcall,
  applyPipelineHostcall,
  applyProviderMutationFiles,
  completeWorkflowHostcall,
  budgetSnapshot,
  initialWorkflowHostState,
  planWorkflowHostcall,
  planProviderAgentHostcall,
  type AgentTurnPlan,
  type WorkflowHostDecision,
  type WorkflowHostState,
} from "../core/workflow-hostcall.ts"
import type { AgentProgressSnapshot, JournalEventDraft, ProviderEvent, WorkflowChildExecutionPolicy, WorkflowChildMessage, WorkflowExecutionOutcome } from "../domain/contracts.ts"
import type { JsonValue } from "../domain/json.ts"
import type { ProviderAgentTurnPort, WorkflowChildResolver, WorkflowExecutor } from "../ports/index.ts"
import { parseErrorMessage } from "../trust/cli-error.ts"
import { parseWorkflowChildLine } from "../trust/hostcall.ts"
import { parseJsonText } from "../trust/json.ts"
import { parseProviderStreamEvent } from "../trust/provider-event.ts"
import { parseCompatibleWorkflowScriptSource } from "../trust/workflow-script.ts"

export class IsolatedWorkflowExecutor implements WorkflowExecutor {
  readonly #policy: WorkflowChildExecutionPolicy
  readonly #providerAgentTurn: ProviderAgentTurnPort | undefined
  readonly #childWorkflowResolver: WorkflowChildResolver | undefined
  readonly #callerSignal: AbortSignal

  constructor(input: {
    readonly policy: WorkflowChildExecutionPolicy
    readonly providerAgentTurn?: ProviderAgentTurnPort | undefined
    readonly childWorkflowResolver?: WorkflowChildResolver | undefined
    readonly callerSignal: AbortSignal
  }) {
    this.#policy = input.policy
    this.#providerAgentTurn = input.providerAgentTurn
    this.#childWorkflowResolver = input.childWorkflowResolver
    this.#callerSignal = input.callerSignal
  }

  async execute(input: Parameters<WorkflowExecutor["execute"]>[0]): Promise<WorkflowExecutionOutcome> {
    const initial = initialWorkflowHostState({ runId: input.run.runId, limits: input.run.limits, approval: input.request.approval, replay: input.replay })
    const run = await this.#runScript({ input, state: initial, source: input.script.source, args: input.run.args })
    const terminal = run.terminal
    switch (terminal.t) {
      case "done":
        return { status: "done", result: terminal.value }
      case "failed":
        return { status: "failed", error: terminal.message }
      case "hostcall":
        throw new Error("workflow child stopped on a hostcall")
    }
  }

  async #runScript(run: {
    readonly input: Parameters<WorkflowExecutor["execute"]>[0]
    readonly state: WorkflowHostState
    readonly source: string
    readonly args: JsonValue
  }): Promise<{ readonly state: WorkflowHostState; readonly terminal: WorkflowChildMessage }> {
    let state = run.state
    const finalLine = await runWorkflowChildProcess({
      initLine: jsonLine({
        source: run.source,
        args: run.args,
        budget: budgetSnapshot(state),
      }),
      policy: this.#policy,
      onLine: async (line) => {
        const message = parseWorkflowChildLine(line)
        switch (message.t) {
          case "done":
          case "failed":
            return { t: "complete", line }
          case "hostcall":
            {
              if (message.op === "agent" && run.input.run.provider === "sdk") {
                const handled = await this.#handleProviderAgent({ state, message, input: run.input })
                state = handled.state
                return { t: "respond", line: handled.line }
              }
              if (message.op === "workflow") {
                const handled = await this.#handleChildWorkflow({ state, message, input: run.input })
                state = handled.state
                return { t: "respond", line: handled.line }
              }
              const handled = handleHostcall(state, message)
              switch (handled.t) {
                case "accepted":
                  state = applyObservedUsage(handled.state, handled.events)
                  for (const event of handled.events) await run.input.emit(event)
                  return { t: "respond", line: okResponse(message.id, handled.value, state) }
                case "rejected":
                  state = handled.state
                  for (const event of handled.events) await run.input.emit(event)
                  return { t: "respond", line: errorResponse(message.id, handled.error, state) }
              }
            }
        }
      },
    })
    const terminal = parseWorkflowChildLine(finalLine)
    return { state, terminal }
  }

  async #handleProviderAgent(input: {
    readonly state: WorkflowHostState
    readonly message: Extract<WorkflowChildMessage, { readonly t: "hostcall"; readonly op: "agent" }>
    readonly input: Parameters<WorkflowExecutor["execute"]>[0]
  }): Promise<{ readonly state: WorkflowHostState; readonly line: string }> {
    const planned = planProviderAgentHostcall(input.state, input.message.call)
    switch (planned.t) {
      case "rejected":
        return { state: planned.state, line: errorResponse(input.message.id, planned.error, planned.state) }
      case "accepted":
        {
          for (const event of planned.events) await input.input.emit(event)
          const provider = this.#providerAgentTurn
          if (provider === undefined) {
            await input.input.emit(agentFailedEvent({ plan: planned.plan, message: "live SDK provider is not configured", durationMs: 0 }))
            return { state: planned.state, line: errorResponse(input.message.id, "live SDK provider is not configured", planned.state) }
          }
          let result
          try {
            result = await runProviderTurn({ provider, plan: planned.plan, input: input.input, callerSignal: this.#callerSignal })
          } catch (error) {
            const message = parseErrorMessage(error)
            await input.input.emit(agentFailedEvent({ plan: planned.plan, message, durationMs: 0 }))
            return { state: planned.state, line: errorResponse(input.message.id, message, planned.state) }
          }
          switch (result.t) {
            case "completed":
              {
                const mutationDecision = applyProviderMutationFiles(planned.state, result.mutationFiles)
                switch (mutationDecision.t) {
                  case "accepted":
                    for (const event of result.events) await input.input.emit(event)
                    {
                      const observed = applyObservedUsage(mutationDecision.state, result.events)
                      return { state: observed, line: okResponse(input.message.id, result.value, observed) }
                    }
                  case "rejected":
                    await input.input.emit(agentFailedEvent({ plan: planned.plan, message: mutationDecision.error, durationMs: 0, kind: "budget" }))
                    return { state: mutationDecision.state, line: errorResponse(input.message.id, mutationDecision.error, mutationDecision.state) }
                }
              }
            case "failed":
              {
                const mutationDecision = applyProviderMutationFiles(planned.state, result.mutationFiles)
                for (const event of result.events) await input.input.emit(event)
                switch (mutationDecision.t) {
                  case "accepted":
                    {
                      const observed = applyObservedUsage(mutationDecision.state, result.events)
                      return { state: observed, line: errorResponse(input.message.id, result.message, observed) }
                    }
                  case "rejected":
                    await input.input.emit(agentFailedEvent({ plan: planned.plan, message: mutationDecision.error, durationMs: 0, kind: "budget" }))
                    {
                      const observed = applyObservedUsage(mutationDecision.state, result.events)
                      return { state: observed, line: errorResponse(input.message.id, mutationDecision.error, observed) }
                    }
                }
              }
          }
          throw new Error("provider turn result was not handled")
        }
      case "replayed":
        {
          for (const event of planned.events) await input.input.emit(event)
          return { state: planned.state, line: okResponse(input.message.id, planned.value, planned.state) }
        }
    }
  }

  async #handleChildWorkflow(input: {
    readonly state: WorkflowHostState
    readonly message: Extract<WorkflowChildMessage, { readonly t: "hostcall"; readonly op: "workflow" }>
    readonly input: Parameters<WorkflowExecutor["execute"]>[0]
  }): Promise<{ readonly state: WorkflowHostState; readonly line: string }> {
    const planned = planWorkflowHostcall(input.state, input.message.call)
    switch (planned.t) {
      case "rejected":
        return { state: planned.state, line: errorResponse(input.message.id, planned.error, planned.state) }
      case "accepted":
        {
          for (const event of planned.events) await input.input.emit(event)
          const resolver = this.#childWorkflowResolver
          if (resolver === undefined) {
            const finished = completeWorkflowHostcall({ state: planned.state, plan: planned.plan, status: "failed" })
            for (const event of finished.events) await input.input.emit(event)
            return { state: finished.state, line: errorResponse(input.message.id, "child workflow resolver is not configured", finished.state) }
          }
          try {
            const resolved = await resolver.resolveChild(planned.plan)
            const script = parseCompatibleWorkflowScriptSource(resolved.source)
            const child = await this.#runScript({ input: input.input, state: planned.state, source: script.source, args: resolved.args })
            switch (child.terminal.t) {
              case "done":
                {
                  const finished = completeWorkflowHostcall({ state: child.state, plan: planned.plan, status: "done", result: child.terminal.value })
                  for (const event of finished.events) await input.input.emit(event)
                  return { state: finished.state, line: okResponse(input.message.id, child.terminal.value, finished.state) }
                }
              case "failed":
                {
                  const finished = completeWorkflowHostcall({ state: child.state, plan: planned.plan, status: "failed" })
                  for (const event of finished.events) await input.input.emit(event)
                  return { state: finished.state, line: errorResponse(input.message.id, child.terminal.message, finished.state) }
                }
              case "hostcall":
                throw new Error("child workflow stopped on a hostcall")
            }
          } catch (error) {
            const finished = completeWorkflowHostcall({ state: planned.state, plan: planned.plan, status: "failed" })
            for (const event of finished.events) await input.input.emit(event)
            return { state: finished.state, line: errorResponse(input.message.id, parseErrorMessage(error), finished.state) }
          }
        }
    }
  }
}

function handleHostcall(state: WorkflowHostState, message: Extract<WorkflowChildMessage, { readonly t: "hostcall" }>): WorkflowHostDecision {
  switch (message.op) {
    case "phase":
      return applyPhaseHostcall(state, message.call)
    case "log":
      return applyLogHostcall(state, message.call)
    case "agent":
      return applyAgentHostcall(state, message.call)
    case "parallel":
      return applyParallelHostcall(state, message.call)
    case "pipeline":
      return applyPipelineHostcall(state, message.call)
    case "workflow":
      throw new Error("workflow hostcall requires child workflow handler")
  }
}

function okResponse(id: number, value: JsonValue, state: WorkflowHostState): string {
  return responseLine(id, true, value, state)
}

function errorResponse(id: number, message: string, state: WorkflowHostState): string {
  return responseLine(id, false, message, state)
}

function jsonLine(value: { readonly source: string; readonly args: JsonValue; readonly budget: ReturnType<typeof budgetSnapshot> }): string {
  const text = JSON.stringify(value)
  return text === undefined ? "null" : text
}

function responseLine(id: number, ok: boolean, value: JsonValue | string, state: WorkflowHostState): string {
  return `${id}\t${ok ? "1" : "0"}\t${JSON.stringify({ value, budget: budgetSnapshot(state) })}`
}

async function runProviderTurn(input: {
  readonly provider: ProviderAgentTurnPort
  readonly plan: AgentTurnPlan
  readonly input: Parameters<WorkflowExecutor["execute"]>[0]
  readonly callerSignal: AbortSignal
}): Promise<
  | { readonly t: "completed"; readonly events: readonly JournalEventDraft[]; readonly value: JsonValue; readonly mutationFiles: readonly string[] }
  | { readonly t: "failed"; readonly events: readonly JournalEventDraft[]; readonly message: string; readonly mutationFiles: readonly string[] }
> {
  const events: JournalEventDraft[] = []
  const maxAttempts = input.plan.schema === undefined ? 1 : input.input.run.limits.schemaRetryLimit + 1
  for (let offset = 0; offset < maxAttempts; offset += 1) {
    const attempt = input.plan.attempt + offset
    if (offset > 0) events.push({ t: "agent_started", node: input.plan.node, attempt })
    const attemptResult = await runProviderAttempt({ ...input, attempt })
    switch (attemptResult.t) {
      case "failed":
        events.push(attemptResult.event)
        return { t: "failed", events, message: attemptResult.message, mutationFiles: attemptResult.mutationFiles }
      case "completed":
        events.push(attemptResult.event)
        return { t: "completed", events, value: attemptResult.value, mutationFiles: attemptResult.mutationFiles }
      case "schema_invalid":
        if (offset + 1 >= maxAttempts) {
          events.push(agentFailedEvent({
            plan: input.plan,
            attempt,
            message: attemptResult.message,
            tokens: attemptResult.tokens,
            toolCalls: attemptResult.toolCalls,
            durationMs: attemptResult.durationMs,
            kind: "malformed-output",
          }))
          return { t: "failed", events, message: attemptResult.message, mutationFiles: attemptResult.mutationFiles }
        }
        {
          const retry = decideStructuredOutputRetry({ isolation: input.plan.isolation, mutationFiles: attemptResult.mutationFiles })
          switch (retry.t) {
            case "retry":
              events.push({ t: "agent_retried", node: input.plan.node, attempt, reason: "schema-invalid", errors: [attemptResult.message] })
              break
            case "fail_closed":
              {
                const message = `${retry.message}: ${attemptResult.message}`
                events.push(agentFailedEvent({
                  plan: input.plan,
                  attempt,
                  message,
                  tokens: attemptResult.tokens,
                  toolCalls: attemptResult.toolCalls,
                  durationMs: attemptResult.durationMs,
                  kind: "malformed-output",
                }))
                return { t: "failed", events, message, mutationFiles: attemptResult.mutationFiles }
              }
          }
        }
    }
  }
  const message = "schema retry loop exhausted"
  events.push(agentFailedEvent({ plan: input.plan, attempt: input.plan.attempt, message, durationMs: 0, kind: "malformed-output" }))
  return { t: "failed", events, message, mutationFiles: [] }
}

async function runProviderAttempt(input: {
  readonly provider: ProviderAgentTurnPort
  readonly plan: AgentTurnPlan
  readonly input: Parameters<WorkflowExecutor["execute"]>[0]
  readonly callerSignal: AbortSignal
  readonly attempt: number
}): Promise<
  | { readonly t: "completed"; readonly event: JournalEventDraft; readonly value: JsonValue; readonly mutationFiles: readonly string[] }
  | { readonly t: "failed"; readonly event: JournalEventDraft; readonly message: string; readonly mutationFiles: readonly string[] }
  | {
    readonly t: "schema_invalid"
    readonly message: string
    readonly tokens: number
    readonly toolCalls: number
    readonly mutationFiles: readonly string[]
    readonly durationMs: number
  }
> {
  let progress = initialAgentProgressSnapshot({ threadId: input.plan.threadId })
  const output = await input.provider.runAgentTurn(providerRequest({
    ...input,
    onStreamEvent: async (event) => {
      const parsed = parseProviderStreamEvent(event.value)
      progress = await applyProviderProgress({ progress, event: parsed, input })
    },
  }))
  let state = initialProviderTurnState()
  for (const raw of output.events) state = foldProviderTurnEvent(state, parseProviderStreamEvent(raw.value))
  const completion = decideProviderTurnCompletion({
    state,
    maxMutationFilesPerAgent: input.input.run.limits.maxMutationFilesPerAgent,
  })
  if (completion.t === "failed") {
    return {
      t: "failed",
      message: completion.message,
      mutationFiles: completion.mutationFiles,
      event: agentFailedEvent({ plan: input.plan, attempt: input.attempt, message: completion.message, tokens: completion.tokens, toolCalls: completion.toolCalls, durationMs: output.durationMs }),
    }
  }
  if (input.plan.schema === undefined) {
    return {
      t: "completed",
      value: completion.finalText,
      mutationFiles: completion.mutationFiles,
      event: agentCompletedEvent({ plan: input.plan, attempt: input.attempt, value: completion.finalText, completion, durationMs: output.durationMs, source: "text" }),
    }
  }
  try {
    const value = parseJsonText(completion.finalText)
    return {
      t: "completed",
      value,
      mutationFiles: completion.mutationFiles,
      event: agentCompletedEvent({ plan: input.plan, attempt: input.attempt, value, completion, durationMs: output.durationMs, source: "provider-schema" }),
    }
  } catch (error) {
    return {
      t: "schema_invalid",
      message: parseErrorMessage(error),
      tokens: completion.tokens,
      toolCalls: completion.toolCalls,
      mutationFiles: completion.mutationFiles,
      durationMs: output.durationMs,
    }
  }
}

function providerRequest(input: {
  readonly provider: ProviderAgentTurnPort
  readonly plan: AgentTurnPlan
  readonly input: Parameters<WorkflowExecutor["execute"]>[0]
  readonly callerSignal: AbortSignal
  readonly onStreamEvent: Parameters<ProviderAgentTurnPort["runAgentTurn"]>[0]["onStreamEvent"]
}) {
  return {
    prompt: frameWorkflowWorkerPrompt({ prompt: input.plan.prompt, label: input.plan.label }),
    effort: input.plan.effort,
    callerSignal: input.callerSignal,
    ...(input.plan.schema === undefined ? {} : { schema: input.plan.schema }),
    ...(modelForTurn(input) === undefined ? {} : { model: modelForTurn(input) }),
    ...(input.plan.isolation === undefined ? {} : { isolation: input.plan.isolation }),
    ...(input.plan.threadId === undefined ? {} : { threadId: input.plan.threadId }),
    ...(input.input.request.options.workingDirectory === undefined ? {} : { workingDirectory: input.input.request.options.workingDirectory }),
    skipGitRepoCheck: input.input.request.options.skipGitRepoCheck,
    ...(input.input.request.options.codexBaseUrl === undefined ? {} : { codexBaseUrl: input.input.request.options.codexBaseUrl }),
    ...(input.input.request.options.codexPathOverride === undefined ? {} : { codexPathOverride: input.input.request.options.codexPathOverride }),
    ...(input.input.request.options.codexConfig === undefined ? {} : { codexConfig: input.input.request.options.codexConfig }),
    onStreamEvent: input.onStreamEvent,
  }
}

async function applyProviderProgress(input: {
  readonly progress: AgentProgressSnapshot
  readonly event: ProviderEvent
  readonly input: {
    readonly provider: ProviderAgentTurnPort
    readonly plan: AgentTurnPlan
    readonly input: Parameters<WorkflowExecutor["execute"]>[0]
    readonly callerSignal: AbortSignal
    readonly attempt: number
  }
}): Promise<AgentProgressSnapshot> {
  switch (input.event.t) {
    case "file_mutations_observed":
      await input.input.input.recordMutationFiles({
        node: input.input.plan.node,
        attempt: input.input.attempt,
        files: input.event.files.map((file) => file.path),
      })
      break
    case "thread_bound":
    case "message_observed":
    case "tool_observed":
    case "usage_observed":
    case "provider_failed":
    case "unknown_telemetry":
      break
  }
  const decision = decideAgentProgress({ previous: input.progress, event: input.event, nowMs: 0 })
  switch (decision.t) {
    case "commit_thread_binding":
      {
        const next: AgentProgressSnapshot = { ...input.progress, thread: { t: "bound", threadId: decision.threadId } }
        await input.input.input.emit({ t: "agent_started", node: input.input.plan.node, attempt: input.input.attempt, threadId: decision.threadId })
        return next
      }
    case "commit_progress":
      await input.input.input.emit(progressJournalEvent({ progress: decision.next, plan: input.input.plan, attempt: input.input.attempt }))
      return decision.next
    case "ignore_progress":
      return input.progress
  }
}

function progressJournalEvent(input: {
  readonly progress: AgentProgressSnapshot
  readonly plan: AgentTurnPlan
  readonly attempt: number
}): Extract<JournalEventDraft, { readonly t: "agent_progress" }> {
  return {
    t: "agent_progress",
    node: input.plan.node,
    attempt: input.attempt,
    tokens: input.progress.tokens,
    toolCalls: input.progress.toolCalls,
    ...(input.progress.lastTool.t === "observed" ? { lastToolName: input.progress.lastTool.name, lastToolSummary: input.progress.lastTool.summary } : {}),
  }
}

function agentCompletedEvent(input: {
  readonly plan: AgentTurnPlan
  readonly attempt: number
  readonly value: JsonValue
  readonly completion: Extract<ReturnType<typeof decideProviderTurnCompletion>, { readonly t: "completed" }>
  readonly durationMs: number
  readonly source: "provider-schema" | "text"
}): JournalEventDraft {
  return {
    t: "agent_completed",
    node: input.plan.node,
    attempt: input.attempt,
    ...(input.completion.thread.t === "bound" ? { threadId: input.completion.thread.threadId } : {}),
    result: input.value,
    tokens: input.completion.tokens,
    toolCalls: input.completion.toolCalls,
    durationMs: input.durationMs,
    source: input.source,
  }
}

function modelForTurn(input: { readonly plan: AgentTurnPlan; readonly input: Parameters<WorkflowExecutor["execute"]>[0] }): string | undefined {
  return input.plan.model === undefined ? input.input.request.options.defaultModel : input.plan.model
}

function agentFailedEvent(input: {
  readonly plan: AgentTurnPlan
  readonly attempt?: number | undefined
  readonly message: string
  readonly tokens?: number | undefined
  readonly toolCalls?: number | undefined
  readonly durationMs: number
  readonly kind?: "provider" | "malformed-output" | "budget" | undefined
}): JournalEventDraft {
  return {
    t: "agent_failed",
    node: input.plan.node,
    attempt: input.attempt === undefined ? input.plan.attempt : input.attempt,
    error: { name: "AgentError", kind: input.kind === undefined ? "provider" : input.kind, message: input.message },
    ...(input.tokens === undefined ? {} : { tokens: input.tokens }),
    ...(input.toolCalls === undefined ? {} : { toolCalls: input.toolCalls }),
    durationMs: input.durationMs,
  }
}
