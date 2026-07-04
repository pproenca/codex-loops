import { mkdir, open, rename } from "node:fs/promises"
import { dirname } from "node:path"
import { randomUUID } from "node:crypto"

import type { DraftWorkflowPlan } from "../domain/contracts.ts"
import type { DraftWorkflowStore } from "../ports/index.ts"

export class FileDraftWorkflowStore implements DraftWorkflowStore {
  async writeDraft(plan: DraftWorkflowPlan): Promise<{ readonly scriptPath: string }> {
    await mkdir(dirname(plan.scriptPath), { recursive: true })
    const tempPath = `${plan.scriptPath}.${randomUUID()}.tmp`
    const handle = await open(tempPath, "w")
    try {
      await handle.writeFile(plan.script, "utf8")
      await handle.sync()
    } finally {
      await handle.close()
    }
    await rename(tempPath, plan.scriptPath)
    return { scriptPath: plan.scriptPath }
  }
}
