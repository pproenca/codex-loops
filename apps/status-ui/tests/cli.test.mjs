import assert from "node:assert/strict"
import { mkdir, mkdtemp, rm } from "node:fs/promises"
import { tmpdir } from "node:os"
import { dirname, join } from "node:path"
import { DatabaseSync } from "node:sqlite"
import { fileURLToPath } from "node:url"
import { spawn } from "node:child_process"
import { test } from "node:test"

const packageRoot = dirname(dirname(fileURLToPath(import.meta.url)))
const binPath = join(packageRoot, "bin", "agent-loops-ui.mjs")

test("CLI prints help and exits successfully", async () => {
  const result = await runCli(["--help"])
  assert.equal(result.code, 0)
  assert.match(result.stdout, /Usage:/)
  assert.match(result.stdout, /agent-loops-ui \[run-id\|latest\]/)
})

test("CLI rejects path-style run selectors", async () => {
  const result = await runCli(["run.jsonl", "--json"])
  assert.equal(result.code, 1)
  assert.match(result.stderr, /path-style run selectors were removed/)
})

test("CLI emits JSON startup envelope and shuts down cleanly", async (t) => {
  const home = await makeTempHome()
  const databasePath = await writeFixtureDatabase(home)
  const child = spawnCli(["run-1", "--host", "127.0.0.1", "--port", "0", "--json"], home)
  const stderr = captureText(child.stderr)
  const envelope = await readStartupEnvelope(t, child, stderr)
  if (envelope === undefined) return
  try {
    assert.equal(envelope.command, "serve")
    assert.equal(envelope.runId, "run-1")
    assert.equal(envelope.databasePath, databasePath)
    assert.equal(Object.hasOwn(envelope, "journalPath"), false)
    assert.match(envelope.url, /^http:\/\/127\.0\.0\.1:\d+\/$/)

    const response = await fetch(new URL("/status.json", envelope.url))
    assert.equal(response.status, 200)
    const payload = await response.json()
    assert.equal(payload.runId, "run-1")
    assert.equal(payload.databasePath, databasePath)
    assert.equal(Object.hasOwn(payload, "journalPath"), false)
    assert.equal(payload.status.runId, "run-1")
    assert.equal(payload.status.workflowName, "Demo")
  } finally {
    child.kill("SIGTERM")
    await rm(home, { recursive: true, force: true })
  }
  assert.equal(await waitForExit(child), 0)
})

test("CLI surfaces malformed journal content through status endpoint", async (t) => {
  const home = await makeTempHome()
  await writeFixtureDatabase(home, { malformed: true })
  const child = spawnCli(["--host", "127.0.0.1", "--port", "0", "--json"], home)
  const stderr = captureText(child.stderr)
  const envelope = await readStartupEnvelope(t, child, stderr)
  if (envelope === undefined) return
  try {
    const response = await fetch(new URL("/status.json", envelope.url))
    assert.equal(response.status, 500)
    assert.match(await response.text(), /SyntaxError/)
  } finally {
    child.kill("SIGTERM")
    await rm(home, { recursive: true, force: true })
  }
  assert.equal(await waitForExit(child), 0)
})

async function runCli(args) {
  const child = spawnCli(args)
  let stdout = ""
  let stderr = ""
  child.stdout.setEncoding("utf8")
  child.stderr.setEncoding("utf8")
  child.stdout.on("data", (chunk) => {
    stdout += chunk
  })
  child.stderr.on("data", (chunk) => {
    stderr += chunk
  })
  const code = await waitForExit(child)
  return { code, stdout, stderr }
}

function spawnCli(args, home) {
  return spawn(process.execPath, [binPath, ...args], {
    cwd: packageRoot,
    env: home === undefined ? process.env : { ...process.env, HOME: home },
    stdio: ["ignore", "pipe", "pipe"],
  })
}

async function makeTempHome() {
  return mkdtemp(join(tmpdir(), "agent-loops-ui-"))
}

async function writeFixtureDatabase(home, options = {}) {
  const databasePath = join(home, ".codex", "workflows", "runs_1.sqlite")
  await mkdir(dirname(databasePath), { recursive: true })
  const db = new DatabaseSync(databasePath)
  try {
    db.exec(`
      create table metadata (key text primary key, value text not null);
      create table events (
        run_id text not null,
        seq integer not null,
        event_type text not null,
        event_json text not null,
        created_at text not null,
        primary key (run_id, seq)
      );
      insert into metadata(key, value) values('latest_run_id', 'run-1');
    `)
    const insert = db.prepare("insert into events(run_id, seq, event_type, event_json, created_at) values(?, ?, ?, ?, ?)")
    insert.run("run-1", 1, "run_opened", options.malformed === true ? "not-json" : JSON.stringify({ t: "run_opened", runId: "run-1", workflowName: "Demo", scriptPath: "workflow.js" }), "2026-01-01T00:00:00.000Z")
    if (options.malformed !== true) insert.run("run-1", 2, "runner_attached", JSON.stringify({ t: "runner_attached" }), "2026-01-01T00:00:01.000Z")
  } finally {
    db.close()
  }
  return databasePath
}

async function readStartupEnvelope(t, child, stderr) {
  try {
    return JSON.parse(await readLine(child.stdout))
  } catch (error) {
    const code = await waitForExit(child)
    if (code === 1 && /listen EPERM: operation not permitted 127\.0\.0\.1/.test(stderr())) {
      t.skip("local listen is blocked in this sandbox")
      return undefined
    }
    throw new Error(`process exited before startup envelope: ${stderr()}`, { cause: error })
  }
}

function captureText(stream) {
  let text = ""
  stream.setEncoding("utf8")
  stream.on("data", (chunk) => {
    text += chunk
  })
  return () => text
}

async function readLine(stream) {
  stream.setEncoding("utf8")
  let buffer = ""
  for await (const chunk of stream) {
    buffer += chunk
    const newline = buffer.indexOf("\n")
    if (newline >= 0) return buffer.slice(0, newline)
  }
  throw new Error("process exited before writing a line")
}

function waitForExit(child) {
  return new Promise((resolve, reject) => {
    child.once("error", reject)
    child.once("exit", (code, signal) => {
      if (signal !== null) {
        reject(new Error(`process exited by signal ${signal}`))
        return
      }
      resolve(code)
    })
  })
}
