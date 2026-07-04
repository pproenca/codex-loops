import { readFile } from "node:fs/promises"
import { createServer, type ServerResponse } from "node:http"
import { extname, resolve, sep } from "node:path"

import type { StatusServerPort } from "../../ports/index.ts"

export class NodeStatusServerPort implements StatusServerPort {
  async start(input: Parameters<StatusServerPort["start"]>[0]): ReturnType<StatusServerPort["start"]> {
    const clients = new Set<ServerResponse>()
    let lastCompactPayload = ""
    const loadPayload = async () => input.loadPayload()
    const writeStatus = async (response: ServerResponse): Promise<void> => {
      try {
        const payload = await loadPayload()
        response.writeHead(200, { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" })
        response.end(payload.prettyPayload)
      } catch (error) {
        response.writeHead(500, { "content-type": "text/plain; charset=utf-8", "cache-control": "no-store" })
        response.end(String(error))
      }
    }
    const writeInitialEvent = async (response: ServerResponse): Promise<void> => {
      try {
        const payload = await loadPayload()
        lastCompactPayload = payload.compactPayload
        response.write(`data: ${payload.compactPayload}\n\n`)
      } catch (error) {
        response.write(`event: error\ndata: ${JSON.stringify(String(error))}\n\n`)
      }
    }
    const broadcast = async (): Promise<void> => {
      if (clients.size === 0) return
      const payload = await loadPayload()
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
          void writeInitialEvent(response)
          request.on("close", () => {
            clients.delete(response)
          })
          return
        case "asset":
          void writeAsset(response, input.ui.rootDirectory, route.path)
          return
        case "index":
          void writeIndex(response, input.ui.rootDirectory)
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
    await new Promise<void>((resolveListen, rejectListen) => {
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
        await new Promise<void>((resolveClose, rejectClose) => {
          server.close((error) => {
            if (error) {
              rejectClose(error)
              return
            }
            resolveClose()
          })
        })
      },
    }
  }
}

async function writeIndex(response: ServerResponse, rootDirectory: string): Promise<void> {
  try {
    await writeFileResponse(response, resolve(rootDirectory, "index.html"), "text/html; charset=utf-8", 200)
  } catch (error) {
    response.writeHead(500, { "content-type": "text/plain; charset=utf-8", "cache-control": "no-store" })
    response.end(`Status UI index.html is missing or unreadable: ${String(error)}`)
  }
}

async function writeAsset(response: ServerResponse, rootDirectory: string, assetPath: string): Promise<void> {
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

async function writeFileResponse(response: ServerResponse, path: string, contentType: string, status: number): Promise<void> {
  const body = await readFile(path)
  response.writeHead(status, { "content-type": contentType, "cache-control": "no-store" })
  response.end(body)
}

function contentTypeFor(path: string): string {
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
