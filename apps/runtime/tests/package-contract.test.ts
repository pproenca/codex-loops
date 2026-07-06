import assert from "node:assert/strict"
import { readFile, readdir, rm, writeFile } from "node:fs/promises"
import { join } from "node:path"
import { test } from "node:test"

import * as api from "../src/index.ts"
import { readRun } from "../src/app/workflow-runner.ts"
import { COMMANDS, renderCommandUsageLines, renderCommandsBlock } from "../src/cli.ts"
import { SqliteJournalReader } from "../src/effects/node/sqlite-journal-reader.ts"
import { makeTempDir } from "./tmp.ts"

test("public API export names stay frozen", () => {
  assert.deepEqual(Object.keys(api).sort(), ["testWorkflow", "workflow"])
})

test("public API arity stays compatible with current exported helpers", () => {
  assert.equal(api.workflow.length, 1)
  assert.equal(api.testWorkflow.length, 1)
})

test("public API return shapes stay compatible", async () => {
  const root = await makeTempDir("agent-loops-api-")
  const previousHome = process.env["HOME"]
  process.env["HOME"] = root
  try {
    const scriptPath = join(root, "api-demo.ts")
    const databasePath = join(root, ".codex", "workflows", "runs_1.sqlite")
    await writeFile(scriptPath, `export const meta = { name: "api-demo", description: "Valid API workflow" }
return agent("do the work", { label: "agent" })
`, "utf8")

    const workflowResult = await api.workflow(scriptPath, { id: 1 }, { provider: "mock" })
    assert.deepEqual(workflowResult, {
      label: "agent",
      summary: "Mock workflow result.",
      prompt: "do the work",
    })

    const testResult = await api.testWorkflow(scriptPath, { id: 2 }, { provider: "mock" })
    if (testResult === undefined) assert.fail("testWorkflow returned undefined")
    assert.equal(testResult.command, "test")
    assert.equal(testResult.snapshot.workflowName, "api-demo")
    assert.equal(testResult.snapshot.status, "done")
    assert.equal(record(testResult.budgetPlan)["provider"], "mock")
    assert.equal(testResult.scriptPath, scriptPath)
    assert.equal(testResult.databasePath, databasePath)
    assert.equal(Object.hasOwn(testResult, "journalPath"), false)
    const { read } = await readRun(String(testResult.snapshot.runId), { journalReader: new SqliteJournalReader(databasePath) })
    assert.equal(read.events.some((event) => event.t === "run_opened"), true)
    assert.equal(read.events.some((event) => event.t === "run_finished"), true)
    const latest = await readRun("latest", { journalReader: new SqliteJournalReader(databasePath) })
    assert.equal(latest.runId, testResult.snapshot.runId)
  } finally {
    if (previousHome === undefined) delete process.env["HOME"]
    else process.env["HOME"] = previousHome
    await rm(root, { recursive: true, force: true })
  }
})

function record(value: unknown): Record<string, unknown> {
  assert.equal(typeof value, "object")
  assert.notEqual(value, null)
  assert.equal(Array.isArray(value), false)
  return value as Record<string, unknown>
}

test("package contract keeps the runtime dependency set explicit", async () => {
  const packageJson = JSON.parse(await readFile(new URL("../package.json", import.meta.url), "utf8"))
  assert.equal(packageJson.name, "agent-loops")
  assert.deepEqual(packageJson.bin, { "agent-loops": "dist/cli.js" })
  assert.deepEqual(Object.keys(packageJson.dependencies).sort(), ["@openai/codex-sdk", "zod"])
  assert.equal(packageJson.dependencies["agent-loops-ui"], undefined)
  assert.deepEqual(Object.keys(packageJson.exports).sort(), ["."])
  assert.deepEqual(Object.keys(packageJson.exports["."]).sort(), ["import", "types"])
})

test("CLI command block is generated from one source", () => {
  assert.match(renderCommandsBlock(), /agent-loops workflow <script-or-name>/)
  assert.match(renderCommandsBlock(), /agent-loops validate <script-or-name>/)
})

test("CLI usage stays contract-compatible", () => {
  assert.deepEqual(renderCommandUsageLines(), [
    "agent-loops draft --goal '<goal>' [--name name] [--output .codex/workflows/name.ts] [--json]",
    "agent-loops validate <script-or-name> --args '<json>' [--json] [--no-input]",
    "agent-loops test <script-or-name> --args '<json>' [--run-id <id>] [--provider mock|sdk] [--budget small|standard|deep] [--json] [--no-input]",
    "agent-loops workflow <script-or-name> --args '<json>' [--run-id <id>] [--provider sdk|mock] [--budget small|standard|deep] [--approved] [--json] [--no-input]",
    "agent-loops workflow <script-or-name> --args '<json>' --background [--status-server] [--json] [--no-input]",
    "agent-loops run <script-or-name> --args '<json>' [--run-id <id>] [--provider sdk|mock] [--budget small|standard|deep] [--approved] [--json] [--no-input]",
    "agent-loops resume [--run-id <id>] [--provider sdk|mock] [--approved] [--json] [--no-input]",
    "agent-loops inspect [--run-id <id>] [--json]",
    "agent-loops status [--run-id <id>] [--event-limit 5] [--json]",
    "agent-loops list [--limit 20] [--event-limit 5] [--json]",
    "agent-loops serve [--run-id <id>] [--host 127.0.0.1] [--port 0] [--json]",
    "agent-loops help",
  ])
})

test("CLI command contract keeps flags and positional bounds compatible", () => {
  const normalize = (spec: { name: string; flags: readonly string[]; maxPositionals: number }) => ({
    name: spec.name,
    flags: spec.flags,
    maxPositionals: Number.isFinite(spec.maxPositionals) ? spec.maxPositionals : "Infinity",
  })

  assert.deepEqual(COMMANDS.map(normalize).map((spec) => spec.name), [
    "draft",
    "validate",
    "test",
    "workflow",
    "run",
    "resume",
    "inspect",
    "status",
    "list",
    "serve",
    "help",
  ])
  assert.equal(COMMANDS.find((spec) => spec.name === "workflow")?.flags.includes("background"), true)
  assert.equal(COMMANDS.find((spec) => spec.name === "resume")?.flags.includes("provider"), true)
  assert.equal(COMMANDS.find((spec) => spec.name === "serve")?.maxPositionals, 0)
})

test("schema file set stays public-contract compatible", async () => {
  const schemaRoot = new URL("../schema/", import.meta.url)
  const names = (await readdir(schemaRoot)).filter((name) => name.endsWith(".json")).sort()

  assert.deepEqual(names, [
    "agent-result.schema.json",
    "cli-error.schema.json",
    "journal-event.schema.json",
    "patch-plan.schema.json",
    "workflow-command.schema.json",
    "workflow-draft.schema.json",
    "workflow-snapshot.schema.json",
    "workload-plan.schema.json",
  ])
})
