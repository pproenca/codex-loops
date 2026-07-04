import type { JournalPointerTarget } from "../../../../src/domain/contracts.ts"
import type { JournalReader } from "../../../../src/ports/index.ts"

export class ConsistencyJournalReader implements JournalReader {
  async readText(_path: string): Promise<string> {
    throw new Error("bad boundary")
  }

  async readMutationText(_path: string): Promise<string> {
    throw new Error("bad boundary")
  }

  async readPointerTarget(_input: { readonly sourcePath: string; readonly target: JournalPointerTarget }): Promise<{ readonly path: string; readonly text: string }> {
    throw new Error("bad boundary")
  }
}
