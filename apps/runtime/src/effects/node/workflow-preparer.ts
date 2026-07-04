import { createHash, randomUUID } from "node:crypto"
import { readFile } from "node:fs/promises"
import { resolve } from "node:path"

import type { WorkflowChildPlan, WorkflowCommandRequest, WorkflowPreparationFacts } from "../../domain/contracts.ts"
import type { WorkflowChildResolver, WorkflowRunPreparer, WorkflowScriptLocator } from "../../ports/index.ts"

export class NodeWorkflowScriptLocator implements WorkflowScriptLocator {
  async locate(request: Parameters<WorkflowScriptLocator["locate"]>[0]): Promise<string> {
    return scriptPathOf(request.script)
  }
}

export class NodeWorkflowPreparer implements WorkflowRunPreparer {
  async prepare(input: Parameters<WorkflowRunPreparer["prepare"]>[0]): Promise<WorkflowPreparationFacts> {
    return {
      runId: randomUUID(),
      cwd: process.cwd(),
      scriptSha256: sha256(input.script.source),
    }
  }
}

export class NodeWorkflowChildResolver implements WorkflowChildResolver {
  async resolveChild(plan: WorkflowChildPlan): ReturnType<WorkflowChildResolver["resolveChild"]> {
    const scriptPath = childScriptPath(plan)
    return {
      scriptPath,
      source: await readFile(scriptPath, "utf8"),
      args: plan.args,
    }
  }
}

function scriptPathOf(script: WorkflowCommandRequest["script"]): string {
  switch (script.t) {
    case "none":
      return resolve("workflow.ts")
    case "unresolved":
      return resolve(script.value)
  }
}

function childScriptPath(plan: WorkflowChildPlan): string {
  switch (plan.ref.t) {
    case "named":
      return resolve(plan.ref.value)
    case "script_path":
      return resolve(plan.ref.scriptPath)
  }
}

function sha256(value: string): string {
  return createHash("sha256").update(value).digest("hex")
}
