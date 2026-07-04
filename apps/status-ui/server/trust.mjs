export function parseCliArgs(argv) {
  const flags = new Map()
  const positionals = []
  for (let index = 0; index < argv.length; index += 1) {
    const value = argv[index]
    if (value === "--help" || value === "-h") return { t: "help" }
    if (value === "--json") {
      flags.set("json", true)
      continue
    }
    if (value.startsWith("--")) {
      const [rawName, inlineValue] = value.slice(2).split("=", 2)
      const next = inlineValue ?? argv[index + 1]
      if (next === undefined || next.startsWith("--")) throw new Error(`missing value for --${rawName}`)
      if (inlineValue === undefined) index += 1
      flags.set(rawName, next)
      continue
    }
    positionals.push(value)
  }
  if (positionals.length !== 1) throw new Error("usage: agent-loops-ui <journal.jsonl> [--host 127.0.0.1] [--port 0] [--json]")
  return {
    t: "serve",
    journalPath: positionals[0],
    host: parseHost(flags.get("host")),
    port: parsePort(flags.get("port")),
    eventLimit: parsePositiveInteger(flags.get("event-limit"), 100, "event-limit"),
    livePollMs: parsePositiveInteger(flags.get("live-poll-ms"), 1000, "live-poll-ms"),
    json: flags.get("json") === true,
  }
}

export function parseRoute(url) {
  if (typeof url !== "string" && url !== undefined) return { t: "not-found" }
  const rawPath = (url ?? "/").split(/[?#]/, 1)[0] ?? "/"
  const rawDecoded = decodePathname(rawPath)
  if (!isSafePath(rawDecoded)) return { t: "not-found" }
  let pathname
  try {
    pathname = new URL(url ?? "/", "http://localhost").pathname
  } catch {
    return { t: "not-found" }
  }
  if (pathname === "/status.json") return { t: "status-json" }
  if (pathname === "/events") return { t: "events" }
  if (pathname.startsWith("/status.json/") || pathname.startsWith("/events/") || pathname.startsWith("/api/")) return { t: "not-found" }

  const decoded = decodePathname(pathname)
  if (!isSafePath(decoded)) return { t: "not-found" }
  if (decoded === "/" || decoded === "") return { t: "index" }

  const assetPath = decoded.replace(/^\/+/, "")
  const lastSegment = assetPath.split("/").at(-1) ?? ""
  if (lastSegment.includes(".")) return { t: "asset", path: assetPath }
  return { t: "index" }
}

export function parseJournalText(text) {
  const events = []
  for (const line of text.split(/\r?\n/)) {
    if (line.trim() === "") continue
    const value = JSON.parse(line)
    if (value === null || typeof value !== "object" || Array.isArray(value)) throw new Error("journal line must be a JSON object")
    if (typeof value.t !== "string") throw new Error("journal event is missing type")
    events.push(value)
  }
  return events
}

function parseHost(value) {
  if (value === undefined) return "127.0.0.1"
  if (typeof value !== "string" || value.trim() === "") throw new Error("host must be a non-empty string")
  return value
}

function parsePort(value) {
  return parsePositiveInteger(value, 0, "port")
}

function parsePositiveInteger(value, fallback, name) {
  if (value === undefined) return fallback
  const parsed = Number(value)
  if (!Number.isInteger(parsed) || parsed < 0 || parsed > 65535) throw new Error(`${name} must be an integer from 0 to 65535`)
  return parsed
}

function decodePathname(pathname) {
  try {
    return decodeURIComponent(pathname)
  } catch {
    return undefined
  }
}

function isSafePath(value) {
  return value !== undefined && !value.includes("\u0000") && !value.includes("\\") && !value.split("/").includes("..")
}
