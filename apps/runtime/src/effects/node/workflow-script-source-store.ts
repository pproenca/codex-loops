import { readFile } from "node:fs/promises"

import type { WorkflowScriptSourceStore } from "../../ports/index.ts"

export class NodeWorkflowScriptSourceStore implements WorkflowScriptSourceStore {
  async read(path: string): Promise<string> {
    return readFile(path, "utf8")
  }
}
