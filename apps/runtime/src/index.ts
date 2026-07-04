import { fileURLToPath } from "node:url"

import { runWorkflowCommandApp } from "./app/workflow-runner.ts"
import { IsolatedWorkflowExecutor } from "./app/isolated-workflow-executor.ts"
import { FileDraftWorkflowStore } from "./consistency/draft-workflow-store.ts"
import { FileJournalStoreFactory } from "./consistency/file-journal-store.ts"
import { FileServePortfileStore } from "./consistency/serve-portfile-store.ts"
import { NodeBackgroundProcessLauncher } from "./effects/node/background-launcher.ts"
import { FileJournalDirectory } from "./effects/node/file-journal-directory.ts"
import { FileJournalReader } from "./effects/node/file-journal-reader.ts"
import { NodeProcessPort } from "./effects/node/process.ts"
import { NodeRunnerHeartbeatPort } from "./effects/node/runner-heartbeat.ts"
import { NodeWorkflowScriptSourceStore } from "./effects/node/workflow-script-source-store.ts"
import { NodeWorkflowChildResolver, NodeWorkflowPreparer, NodeWorkflowScriptLocator } from "./effects/node/workflow-preparer.ts"
import { SdkProviderAgentTurnPort } from "./effects/sdk/provider-turn.ts"
import { parseContainmentPolicy, parseRunnerHeartbeatPolicy, parseWorkflowChildExecutionPolicy } from "./trust/containment.ts"
import { parseWorkflowProgrammaticCall } from "./trust/workflow-command.ts"

export async function workflow(nameOrRef: unknown, ...rest: unknown[]) {
  const result = await runWorkflowCommandApp(parseWorkflowProgrammaticCall("workflow", nameOrRef, rest), defaultEnvironment())
  return result.status === "completed" ? result.snapshot.result : undefined
}

export async function testWorkflow(nameOrRef: unknown, ...rest: unknown[]) {
  const result = await runWorkflowCommandApp(parseWorkflowProgrammaticCall("test", nameOrRef, rest), defaultEnvironment())
  return result.status === "completed" ? {
    command: result.command,
    snapshot: result.snapshot,
    budgetPlan: result.budgetPlan,
    journalPath: result.journalPath,
    scriptPath: result.scriptPath,
  } : undefined
}

function defaultEnvironment() {
  return {
    journalReader: new FileJournalReader(),
    journalDirectory: new FileJournalDirectory(),
    journalStoreFactory: new FileJournalStoreFactory(new NodeProcessPort()),
    servePortfileStore: new FileServePortfileStore(),
    draftWorkflowStore: new FileDraftWorkflowStore(),
    processPort: new NodeProcessPort(),
    workflowScriptLocator: new NodeWorkflowScriptLocator(),
    workflowPreparer: new NodeWorkflowPreparer(),
    workflowScriptSourceStore: new NodeWorkflowScriptSourceStore(),
    workflowExecutor: new IsolatedWorkflowExecutor({
      policy: parseWorkflowChildExecutionPolicy({}),
      providerAgentTurn: new SdkProviderAgentTurnPort(parseContainmentPolicy({})),
      childWorkflowResolver: new NodeWorkflowChildResolver(),
      callerSignal: new AbortController().signal,
    }),
    backgroundLauncher: new NodeBackgroundProcessLauncher(fileURLToPath(new URL("cli.ts", import.meta.url))),
    runnerHeartbeat: new NodeRunnerHeartbeatPort(parseRunnerHeartbeatPolicy({})),
  }
}
