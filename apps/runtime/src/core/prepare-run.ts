import type { CompatibleWorkflowScript, PreparedWorkflowRun, ProviderSelection, WorkflowCommandRequest, WorkflowLimits, WorkflowPreparationFacts, WorkflowProvider, WorkflowRunnableCommand } from "../domain/contracts.ts"
import type { JsonValue } from "../domain/json.ts"

export type PrepareWorkflowRunInput = {
  readonly request: WorkflowCommandRequest
  readonly provider: WorkflowProvider
  readonly scriptPath: string
  readonly script: CompatibleWorkflowScript
  readonly facts: WorkflowPreparationFacts
}

export function prepareWorkflowRun(input: PrepareWorkflowRunInput): PreparedWorkflowRun {
  const limits = input.request.options.limits
  const runId = runIdOf(input.request.requestedRunId, input.facts.runId)
  return {
    command: input.request.command,
    runId,
    workflowName: input.script.meta.name,
    scriptPath: input.scriptPath,
    scriptSha256: input.facts.scriptSha256,
    databasePath: input.facts.databasePath,
    args: input.request.args,
    provider: input.provider,
    budgetPlan: budgetPlan({ provider: input.provider, limits }),
    limits,
    runtimeContract: runtimeContract({ command: input.request.command, limits }),
    requestedRunId: input.request.requestedRunId,
  }
}

export function selectWorkflowProvider(selection: ProviderSelection): WorkflowProvider {
  switch (selection.t) {
    case "explicit":
      return selection.provider
    case "default_for_command":
      return selection.fallback
  }
}

export function selectResumeWorkflowProvider(input: {
  readonly selection: ProviderSelection
  readonly recordedProvider: WorkflowProvider
}): WorkflowProvider {
  switch (input.selection.t) {
    case "explicit":
      return input.selection.provider
    case "default_for_command":
      return input.recordedProvider
  }
}

export function runnerAttachMode(command: WorkflowRunnableCommand): "fresh" | "resume" {
  switch (command) {
    case "resume":
      return "resume"
    case "run":
    case "test":
    case "validate":
    case "workflow":
      return "fresh"
  }
}

function runIdOf(requested: WorkflowCommandRequest["requestedRunId"], generated: string): string {
  switch (requested.t) {
    case "none":
      return generated
    case "requested":
      return requested.value
  }
}

function budgetPlan(input: { readonly provider: WorkflowProvider; readonly limits: WorkflowLimits }): JsonValue {
  return {
    provider: input.provider,
    limits: input.limits,
    expectedAgents: { minimum: 0, maximum: input.limits.maxAgents, basis: "prepared workflow limits" },
    workload: {
      scopeKind: "bounded",
      batchable: false,
      runCompleteness: "full",
      basis: "trusted request limits and host scheduling policy",
      maxMutationFilesPerRun: input.limits.maxMutationFilesPerRun,
      maxMutationFilesPerAgent: input.limits.maxMutationFilesPerAgent,
      maxPromptBytesPerAgent: input.limits.maxPromptBytesPerAgent,
    },
    modelPolicySummary: {
      defaultEffort: "medium",
      minEffort: "medium",
      maxEffort: "xhigh",
      disallowedEfforts: [],
    },
    writeScope: { posture: "read-only", summary: "host policy records requested isolation per agent and fails closed on unsafe retries" },
    tokenWarning: "provider usage is journaled as observed; explicit token budgets are enforced before future agent starts",
  }
}

function runtimeContract(input: { readonly command: WorkflowCommandRequest["command"]; readonly limits: WorkflowLimits }): JsonValue {
  const taskBudgetTokens = input.limits.taskBudgetTokens
  const minRemainingTokensForAgent = input.limits.minRemainingTokensForAgent
  return {
    activation: { allowed: true, source: "cli-command", command: input.command, reason: "local workflow command accepted by the host runner" },
    permission: permissionContract(input.command),
    structuredOutput: { mode: "provider-schema", failClosed: true, schemaRetryLimit: input.limits.schemaRetryLimit },
    scheduling: {
      maxAgents: input.limits.maxAgents,
      maxConcurrentAgents: input.limits.maxConcurrentAgents,
      queueExcessAgents: true,
      queueStateVisible: true,
      releaseSlotsOnTerminalState: true,
    },
    budgeting: {
      accountingFields: ["tokens"],
      thresholdPolicy: "script-visible budget exposes total, spent(), and remaining(); no task budget leaves remaining() unbounded; explicit task budgets refuse future agent scheduling after observed spend reaches the ceiling; in-flight agents are not retroactively killed",
      ...(taskBudgetTokens === undefined ? {} : { taskBudgetTokens }),
      ...(minRemainingTokensForAgent === undefined ? {} : { minRemainingTokensForAgent }),
    },
    resume: { cacheKey: "runId+phaseTitle+label+promptHash+schemaHash+optionsHash", completedNodesReplayFromJournal: true },
    remote: { supported: false, reason: "this local runner resumes from durable local journals" },
  }
}

function permissionContract(command: WorkflowCommandRequest["command"]): JsonValue {
  return command === "test" || command === "validate"
    ? { decision: "allow", source: "mock-or-validate-command", autoDenied: false, ruleText: "mock/validate commands do not grant live external write authority" }
    : { decision: "caller-owned", source: "request approval", autoDenied: false, ruleText: "full-access provider turns require explicit approval" }
}
