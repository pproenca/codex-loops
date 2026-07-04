import { readFile } from "node:fs/promises"
import { createServer } from "node:http"
import { extname, resolve, sep } from "node:path"

export async function readText(path) {
  return readFile(path, "utf8")
}

export async function startStatusServer(input) {
  const clients = new Set()
  let lastCompactPayload = ""

  const writeStatus = async (response) => {
    try {
      const payload = await input.loadPayload()
      response.writeHead(200, { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" })
      response.end(payload.prettyPayload)
    } catch (error) {
      response.writeHead(500, { "content-type": "text/plain; charset=utf-8", "cache-control": "no-store" })
      response.end(String(error))
    }
  }

  const broadcast = async () => {
    if (clients.size === 0) return
    const payload = await input.loadPayload()
    if (payload.compactPayload === lastCompactPayload) return
    lastCompactPayload = payload.compactPayload
    for (const client of clients) client.write(`data: ${payload.compactPayload}\n\n`)
  }

  const server = createServer((request, response) => {
    const route = input.parseRoute(request.url)
    switch (route.t) {
      case "status-json":
        void writeStatus(response)
        return
      case "events":
        response.writeHead(200, { "content-type": "text/event-stream", "cache-control": "no-store", connection: "keep-alive" })
        clients.add(response)
        void input.loadPayload().then((payload) => {
          lastCompactPayload = payload.compactPayload
          response.write(`data: ${payload.compactPayload}\n\n`)
        }).catch((error) => response.write(`event: error\ndata: ${JSON.stringify(String(error))}\n\n`))
        request.on("close", () => clients.delete(response))
        return
      case "asset":
        void writeAsset(response, input.uiRoot, route.path)
        return
      case "index":
        void writeIndex(response, input.uiRoot)
        return
      case "not-found":
        response.writeHead(404, { "content-type": "text/plain; charset=utf-8", "cache-control": "no-store" })
        response.end("Not found")
        return
    }
  })

  const heartbeat = setInterval(() => {
    for (const client of clients) client.write(": heartbeat\n\n")
  }, 15_000)
  heartbeat.unref()

  const livePoll = setInterval(() => {
    void broadcast().catch(() => {})
  }, input.livePollMs)
  livePoll.unref()

  await new Promise((resolveListen, rejectListen) => {
    server.once("error", rejectListen)
    server.listen(input.port, input.host, () => {
      server.off("error", rejectListen)
      resolveListen()
    })
  })

  return {
    address: server.address(),
    async close() {
      clearInterval(heartbeat)
      clearInterval(livePoll)
      for (const client of clients) client.end()
      clients.clear()
      await new Promise((resolveClose, rejectClose) => {
        server.close((error) => {
          if (error) rejectClose(error)
          else resolveClose()
        })
      })
    },
  }
}

async function writeIndex(response, rootDirectory) {
  try {
    await writeFileResponse(response, resolve(rootDirectory, "index.html"), "text/html; charset=utf-8", 200)
  } catch (error) {
    response.writeHead(500, { "content-type": "text/plain; charset=utf-8", "cache-control": "no-store" })
    response.end(`Status UI index.html is missing or unreadable: ${String(error)}`)
  }
}

async function writeAsset(response, rootDirectory, assetPath) {
  const root = resolve(rootDirectory)
  const target = resolve(root, assetPath)
  if (target !== root && !target.startsWith(`${root}${sep}`)) {
    response.writeHead(404, { "content-type": "text/plain; charset=utf-8", "cache-control": "no-store" })
    response.end("Not found")
    return
  }
  try {
    await writeFileResponse(response, target, contentTypeFor(target), 200)
  } catch {
    response.writeHead(404, { "content-type": "text/plain; charset=utf-8", "cache-control": "no-store" })
    response.end("Not found")
  }
}

async function writeFileResponse(response, path, contentType, status) {
  const body = await readFile(path)
  response.writeHead(status, { "content-type": contentType, "cache-control": "no-store" })
  response.end(body)
}

function contentTypeFor(path) {
  switch (extname(path)) {
    case ".html":
      return "text/html; charset=utf-8"
    case ".js":
      return "application/javascript; charset=utf-8"
    case ".css":
      return "text/css; charset=utf-8"
    case ".svg":
      return "image/svg+xml"
    case ".png":
      return "image/png"
    case ".ico":
      return "image/x-icon"
    case ".map":
      return "application/json; charset=utf-8"
    case ".txt":
      return "text/plain; charset=utf-8"
    default:
      return "application/octet-stream"
  }
}
