import { z } from "zod"

import type { Proven } from "../domain/brand.ts"
import type { JournalMutationRecord } from "../domain/contracts.ts"
import { proven } from "./proven.ts"

const mutationRecordSchema = z.object({
  node: z.string().min(1),
  attempt: z.number().int().positive(),
  files: z.array(z.string().min(1)),
}).strict()

export function parseJournalMutationText(text: string): Proven<readonly string[]> {
  const files: string[] = []
  for (const line of text.split("\n")) {
    if (line.length === 0) continue
    const record = parseJournalMutationLine(line)
    for (const file of record.files) {
      if (!files.includes(file)) files.push(file)
    }
  }
  return proven(files)
}

export function parseJournalMutationLine(line: string): Proven<JournalMutationRecord> {
  return proven(mutationRecordSchema.parse(JSON.parse(line)))
}
