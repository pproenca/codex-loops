import { z } from "zod"

import type { Proven } from "../domain/brand.ts"
import type { CliRequest, ResumeCommandRequest } from "../domain/contracts.ts"
import { proven } from "./proven.ts"
import { parseWorkflowCommandCliRequest } from "./workflow-command.ts"

const DEFAULT_JOURNAL_PATH = ".agent-loops-runs/latest.json"
const flagValueSchema = z.union([z.string(), z.boolean()])

export function parseResumeCliRequest(input: Proven<CliRequest>): Proven<ResumeCommandRequest> {
  const workflow = parseWorkflowCommandCliRequest(input)
  const command = z.literal("resume").parse(workflow.command)
  const flags = z.record(z.string(), flagValueSchema).parse(input.flags)
  return proven({
    command,
    journalPath: parseJournalPath(workflow),
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

function parseJournalPath(value: Pick<ReturnType<typeof parseWorkflowCommandCliRequest>, "journal">): string {
  switch (value.journal.t) {
    case "none":
      return DEFAULT_JOURNAL_PATH
    case "requested":
      return value.journal.path
  }
}
