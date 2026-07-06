import type { JournalReader } from "../../../../src/ports/index.ts"

export class ConsistencyJournalReader implements JournalReader {
  async resolveRun(input: Parameters<JournalReader["resolveRun"]>[0]): Promise<{ readonly runId: string; readonly databasePath: string }> {
    return { runId: input.runId, databasePath: "" }
  }

  async readText(_runId: string): Promise<string> {
    throw new Error("bad boundary")
  }

  async readMutationText(_runId: string): Promise<string> {
    throw new Error("bad boundary")
  }

}
