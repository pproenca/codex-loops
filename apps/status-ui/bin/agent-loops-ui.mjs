#!/usr/bin/env node
import { fileURLToPath } from "node:url"

import { startStatusServer } from "../server/effects.mjs"
import { buildStatusPayload } from "../server/project.mjs"
import { defaultWorkflowDatabasePath, readRunEvents, resolveRun } from "../server/sqlite.mjs"
import { parseCliArgs, parseRoute } from "../server/trust.mjs"

const help = `agent-loops-ui

Usage:
  agent-loops-ui [run-id|latest] [--host 127.0.0.1] [--port 0] [--json]

Options:
  --host <host>              Host to bind. Defaults to 127.0.0.1.
  --port <port>              Port to bind. Defaults to 0.
  --event-limit <count>      Number of journal events in status payload. Defaults to 100.
  --live-poll-ms <ms>        Journal polling interval. Defaults to 1000.
  --json                     Print a JSON startup envelope.
`

try {
  const request = parseCliArgs(process.argv.slice(2))
  if (request.t === "help") {
    process.stdout.write(help)
    process.exit(0)
  }
  const uiRoot = fileURLToPath(new URL("../dist/", import.meta.url))
  const databasePath = defaultWorkflowDatabasePath()
  const loadPayload = async () => {
    const run = readRunEvents({ databasePath, selector: request.selector })
    const payload = buildStatusPayload({ databasePath: run.databasePath, runId: run.runId, events: run.events, eventLimit: request.eventLimit })
    return { compactPayload: JSON.stringify(payload), prettyPayload: JSON.stringify(payload, null, 2) }
  }
  const server = await startStatusServer({
    host: request.host,
    port: request.port,
    livePollMs: request.livePollMs,
    uiRoot,
    parseRoute,
    loadPayload,
  })
  const address = server.address
  const port = typeof address === "object" && address !== null ? address.port : request.port
  const url = `http://${request.host}:${port}/`
  const run = resolveRun({ databasePath, selector: request.selector })
  process.stdout.write(request.json ? `${JSON.stringify({ command: "serve", runId: run.runId, databasePath: run.databasePath, url })}\n` : `Serving Codex Loops UI at ${url}\n`)
  await waitForShutdown()
  await server.close()
} catch (error) {
  process.stderr.write(`${error instanceof Error ? error.message : String(error)}\n`)
  process.exit(1)
}

function waitForShutdown() {
  return new Promise((resolve) => {
    process.once("SIGINT", resolve)
    process.once("SIGTERM", resolve)
  })
}
