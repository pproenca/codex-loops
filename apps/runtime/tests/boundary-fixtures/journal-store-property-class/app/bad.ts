import type { CommittedJournalEvent, JournalCommitRequest, PreparedWorkflowRun } from "../../../../src/domain/contracts.ts"

export class EscapedStore {
  readonly ["commit"] = async (_request: JournalCommitRequest): Promise<CommittedJournalEvent> => {
    return { seq: 1, event: { seq: 1, t: "run_finished", status: "done", totalTokens: 0, totalToolCalls: 0, durationMs: 0 } }
  }

  readonly ["initializeRun"] = async (_run: PreparedWorkflowRun): Promise<CommittedJournalEvent> => {
    return { seq: 1, event: { seq: 1, t: "run_finished", status: "done", totalTokens: 0, totalToolCalls: 0, durationMs: 0 } }
  }
}
