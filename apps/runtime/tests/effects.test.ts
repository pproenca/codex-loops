import assert from "node:assert/strict"
import { spawnSync } from "node:child_process"
import { readFile, realpath, rm, writeFile } from "node:fs/promises"
import { join } from "node:path"
import { test } from "node:test"

import { inspectGitWorktree } from "../src/app/git-preflight.ts"
import { NodeWorkflowPreparer, NodeWorkflowScriptLocator } from "../src/effects/node/workflow-preparer.ts"
import { NodeGitPort } from "../src/effects/node/git.ts"
import { parseCompatibleWorkflowScriptSource } from "../src/trust/workflow-script.ts"
import { parseCliArgv } from "../src/trust/cli.ts"
import { parseWorkflowCommandCliRequest } from "../src/trust/workflow-command.ts"
import { makeTempDir } from "./tmp.ts"

test("Node workflow preparer uses trusted workflow meta for the workflow name", async () => {
  const root = await makeTempDir("agent-loops-preparer-")
  try {
    const scriptPath = join(root, "filename.ts")
    await writeFile(scriptPath, `export const meta = { name: "trusted-name", description: "Valid workflow" }
return agent("do the work", { label: "agent" })
`, "utf8")
    const request = parseWorkflowCommandCliRequest(parseCliArgv(["test", scriptPath, "--mock"]))
    const located = await new NodeWorkflowScriptLocator().locate(request)
    const script = parseCompatibleWorkflowScriptSource(await readFile(located, "utf8"))
    const facts = await new NodeWorkflowPreparer().prepare({ script })

    assert.match(facts.runId, /^[0-9a-f-]+$/)
    assert.match(facts.scriptSha256, /^[0-9a-f]{64}$/)
  } finally {
    await rm(root, { recursive: true, force: true })
  }
})

test("Node git port probes repo root and dirty state through bounded subprocesses", async () => {
  const git = spawnSync("git", ["--version"], { encoding: "utf8" })
  if (git.status !== 0) return
  const root = await makeTempDir("agent-loops-git-")
  try {
    const init = spawnSync("git", ["init"], { cwd: root, encoding: "utf8" })
    assert.equal(init.status, 0, init.stderr)
    const port = new NodeGitPort({ timeoutMs: 1_000, maxStdoutBytes: 16_000, maxStderrBytes: 16_000 })
    const resolvedRoot = await realpath(root)

    assert.deepEqual(await inspectGitWorktree(root, port), { t: "repo", root: resolvedRoot, dirty: false })
    await writeFile(join(root, "dirty.txt"), "dirty\n", "utf8")
    assert.deepEqual(await inspectGitWorktree(root, port), { t: "repo", root: resolvedRoot, dirty: true })
  } finally {
    await rm(root, { recursive: true, force: true })
  }
})
