import { z } from "zod"

import type { Proven } from "../domain/brand.ts"
import type { CliRequest, ResumeCommandRequest } from "../domain/contracts.ts"
import { proven } from "./proven.ts"
import { parseWorkflowCommandCliRequest } from "./workflow-command.ts"

const DEFAULT_RUN_ID = "latest"
const flagValueSchema = z.union([z.string(), z.boolean()])

export function parseResumeCliRequest(input: Proven<CliRequest>): Proven<ResumeCommandRequest> {
  const workflow = parseWorkflowCommandCliRequest(input)
  const command = z.literal("resume").parse(workflow.command)
  const flags = z.record(z.string(), flagValueSchema).parse(input.flags)
  return proven({
    command,
    runId: parseRunId(workflow.requestedRunId),
    provider: workflow.provider,
    approval: workflow.approval,
    noInput: workflow.noInput,
    json: flags["json"] === true,
    quiet: flags["quiet"] === true,
    background: workflow.background,
    backgroundWorker: workflow.backgroundWorker,
    options: workflow.options,
  })
}

function parseRunId(value: Pick<ReturnType<typeof parseWorkflowCommandCliRequest>, "requestedRunId">["requestedRunId"]): string {
  switch (value.t) {
    case "none":
      return DEFAULT_RUN_ID
    case "requested":
      return value.value
  }
}
