import { readFile } from "node:fs/promises"
import { dirname, resolve } from "node:path"

import type { JournalReader } from "../../ports/index.ts"

export class FileJournalReader implements JournalReader {
  async readText(path: string): Promise<string> {
    return readFile(path, "utf8")
  }

  async readMutationText(journalPath: string): Promise<string> {
    return readFile(`${journalPath}.mutations.jsonl`, "utf8")
  }

  async readPointerTarget(input: Parameters<JournalReader["readPointerTarget"]>[0]): Promise<{ readonly path: string; readonly text: string }> {
    const path = resolve(dirname(input.sourcePath), input.target)
    return { path, text: await readFile(path, "utf8") }
  }
}
