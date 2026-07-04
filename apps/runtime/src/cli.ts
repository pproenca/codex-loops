#!/usr/bin/env node
import { fileURLToPath } from "node:url"

import { IsolatedWorkflowExecutor } from "./app/isolated-workflow-executor.ts"
import { runServeCommandApp, runWorkflowApp } from "./app/workflow-runner.ts"
import { FileDraftWorkflowStore } from "./consistency/draft-workflow-store.ts"
import { FileJournalStoreFactory } from "./consistency/file-journal-store.ts"
import { FileServePortfileStore } from "./consistency/serve-portfile-store.ts"
import { COMMANDS } from "./domain/cli-contract.ts"
import { isCliEntrypoint, NodeBackgroundProcessLauncher } from "./effects/node/background-launcher.ts"
import { FileJournalDirectory } from "./effects/node/file-journal-directory.ts"
import { FileJournalReader } from "./effects/node/file-journal-reader.ts"
import { NodeProcessPort } from "./effects/node/process.ts"
import { NodeRunnerHeartbeatPort } from "./effects/node/runner-heartbeat.ts"
import { NodeStatusServerPort } from "./effects/node/status-server.ts"
import { NodeWorkflowScriptSourceStore } from "./effects/node/workflow-script-source-store.ts"
import { NodeWorkflowChildResolver, NodeWorkflowPreparer, NodeWorkflowScriptLocator } from "./effects/node/workflow-preparer.ts"
import { SdkProviderAgentTurnPort } from "./effects/sdk/provider-turn.ts"
import { parseCliArgv } from "./trust/cli.ts"
import { parseCliFailure } from "./trust/cli-error.ts"
import { parseContainmentPolicy, parseRunnerHeartbeatPolicy, parseWorkflowChildExecutionPolicy } from "./trust/containment.ts"
import { parseServeCliRequest } from "./trust/serve-command.ts"
export { COMMANDS } from "./domain/cli-contract.ts"

export function renderCommandUsageLines(): readonly string[] {
  return COMMANDS.flatMap((spec) => spec.usage.map((usage) => `agent-loops ${usage}`))
}

export function renderCommandsBlock(): string {
  return ["```bash", ...renderCommandUsageLines(), "```"].join("\n")
}

export function helpText(): string {
  return `agent-loops

Commands:
${renderCommandUsageLines().map((line) => `  ${line}`).join("\n")}
`
}

export async function main(argv: readonly string[]): Promise<number> {
  const request = parseCliArgv(argv)
  const json = request.flags["json"] === true
  if (request.command === "help") {
    process.stdout.write(helpText())
    return 0
  }
  if (request.command === "serve") {
    const processPort = new NodeProcessPort()
    const statusUiRootDirectory = fileURLToPath(new URL("../dist/status-ui/", import.meta.url))
    const serve = await runServeCommandApp(parseServeCliRequest(request), {
      journalReader: new FileJournalReader(),
      processPort,
      servePortfileStore: new FileServePortfileStore(),
      statusServer: new NodeStatusServerPort(),
      statusUiRootDirectory,
      workflowScriptSourceStore: new NodeWorkflowScriptSourceStore(),
    })
    process.stdout.write(json
      ? `${JSON.stringify(serve.envelope)}\n`
      : `Serving workflow status at ${serve.envelope.url}\n`)
    await waitForShutdown()
    await serve.close()
    return 0
  }
  const result = await runWorkflowApp(request, {
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
    backgroundLauncher: new NodeBackgroundProcessLauncher(fileURLToPath(import.meta.url)),
    runnerHeartbeat: new NodeRunnerHeartbeatPort(parseRunnerHeartbeatPolicy({})),
  })
  if (result.status === "inspected") {
    writeResult(json, { command: "inspect", snapshot: result.snapshot }, JSON.stringify(result.snapshot, null, 2))
    return 0
  }
  if (result.status === "summarized") {
    writeResult(json, { command: "status", status: result.summary }, JSON.stringify(result.summary, null, 2))
    return 0
  }
  if (result.status === "completed") {
    writeResult(json, {
      command: result.command,
      snapshot: result.snapshot,
      budgetPlan: result.budgetPlan,
      journalPath: result.journalPath,
      scriptPath: result.scriptPath,
    }, `Workflow ${result.snapshot.status}. Journal: ${result.journalPath}`)
    return 0
  }
  if (result.status === "validated") {
    writeResult(json, {
      command: result.command,
      workflowName: result.workflowName,
      scriptPath: result.scriptPath,
      validation: result.compatibility,
    }, `Validated workflow "${result.workflowName}" at ${result.scriptPath}.`)
    return 0
  }
  if (result.status === "listed") {
    writeResult(json, { command: "list", workflows: result.workflows }, JSON.stringify(result.workflows, null, 2))
    return 0
  }
  if (result.status === "async_launched") {
    writeResult(json, result, `Launched workflow "${result.workflowName}" in the background. Journal: ${result.journalPath}${result.statusUrl === undefined ? "" : ` Status: ${result.statusUrl}`}`)
    return 0
  }
  if (result.status === "drafted") {
    writeResult(json, {
      command: result.command,
      workflowName: result.workflowName,
      scriptPath: result.scriptPath,
      validation: result.validation,
      nextSteps: result.nextSteps,
    }, `Drafted workflow "${result.workflowName}" at ${result.scriptPath}.`)
    return 0
  }
  process.stderr.write("agent-loops: command is not available through the workflow runner\n")
  return 2
}

function waitForShutdown(): Promise<void> {
  return new Promise((resolveWait) => {
    process.once("SIGINT", resolveWait)
    process.once("SIGTERM", resolveWait)
  })
}

function writeResult(json: boolean, payload: object, human: string): void {
  process.stdout.write(json ? `${JSON.stringify(payload, null, 2)}\n` : `${human}\n`)
}

if (await isCliEntrypoint({ moduleUrl: import.meta.url, argvEntry: process.argv[1] })) {
  try {
    process.exitCode = await main(process.argv.slice(2))
  } catch (error) {
    const failure = parseCliFailure(error)
    process.stderr.write(`${failure.message}\n`)
    process.stderr.write(`${JSON.stringify(failure.payload)}\n`)
    process.exitCode = failure.exitCode
  }
}
