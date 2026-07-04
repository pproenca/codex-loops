import type { CommittedJournalEvent, JournalCommitRequest, PreparedWorkflowRun } from "../../../../src/domain/contracts.ts"
import type { JournalStore as Store } from "../../../../src/ports/index.ts"

export class AppJournalStore implements Store {
  async commit(_request: JournalCommitRequest): Promise<CommittedJournalEvent> {
    return { seq: 1, event: { seq: 1, t: "run_finished", status: "done", totalTokens: 0, totalToolCalls: 0, durationMs: 0 } }
  }

  async initializeRun(_run: PreparedWorkflowRun): Promise<CommittedJournalEvent> {
    return { seq: 1, event: { seq: 1, t: "run_finished", status: "done", totalTokens: 0, totalToolCalls: 0, durationMs: 0 } }
  }

  async heartbeat(): Promise<CommittedJournalEvent> {
    return { seq: 1, event: { seq: 1, t: "runner_heartbeat", pid: 1 } }
  }

  async recordMutationFiles(): Promise<void> {
  }

  async release(): Promise<void> {
  }
}
