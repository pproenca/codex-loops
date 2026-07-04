import assert from "node:assert/strict"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"
import { spawn } from "node:child_process"
import { test } from "node:test"

const packageRoot = dirname(dirname(fileURLToPath(import.meta.url)))
const binPath = join(packageRoot, "bin", "agent-loops-ui.mjs")
const validJournalPath = join(packageRoot, "tests", "fixtures", "valid-journal.jsonl")
const malformedJournalPath = join(packageRoot, "tests", "fixtures", "malformed-journal.jsonl")

test("CLI prints help and exits successfully", async () => {
  const result = await runCli(["--help"])
  assert.equal(result.code, 0)
  assert.match(result.stdout, /Usage:/)
  assert.match(result.stdout, /agent-loops-ui <journal\.jsonl>/)
})

test("CLI rejects missing journal path", async () => {
  const result = await runCli(["--json"])
  assert.equal(result.code, 1)
  assert.match(result.stderr, /usage: agent-loops-ui <journal\.jsonl>/)
})

test("CLI emits JSON startup envelope and shuts down cleanly", async (t) => {
  const child = spawnCli([validJournalPath, "--host", "127.0.0.1", "--port", "0", "--json"])
  const stderr = captureText(child.stderr)
  const envelope = await readStartupEnvelope(t, child, stderr)
  if (envelope === undefined) return
  try {
    assert.equal(envelope.command, "serve")
    assert.equal(envelope.journalPath, validJournalPath)
    assert.match(envelope.url, /^http:\/\/127\.0\.0\.1:\d+\/$/)

    const response = await fetch(new URL("/status.json", envelope.url))
    assert.equal(response.status, 200)
    const payload = await response.json()
    assert.equal(payload.journalPath, validJournalPath)
    assert.equal(payload.status.runId, "run-1")
    assert.equal(payload.status.workflowName, "Demo")
  } finally {
    child.kill("SIGTERM")
  }
  assert.equal(await waitForExit(child), 0)
})

test("CLI surfaces malformed journal content through status endpoint", async (t) => {
  const child = spawnCli([malformedJournalPath, "--host", "127.0.0.1", "--port", "0", "--json"])
  const stderr = captureText(child.stderr)
  const envelope = await readStartupEnvelope(t, child, stderr)
  if (envelope === undefined) return
  try {
    const response = await fetch(new URL("/status.json", envelope.url))
    assert.equal(response.status, 500)
    assert.match(await response.text(), /SyntaxError/)
  } finally {
    child.kill("SIGTERM")
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

function spawnCli(args) {
  return spawn(process.execPath, [binPath, ...args], {
    cwd: packageRoot,
    stdio: ["ignore", "pipe", "pipe"],
  })
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
