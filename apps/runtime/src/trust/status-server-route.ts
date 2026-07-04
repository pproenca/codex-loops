export type ParsedStatusServerRoute =
  | { readonly t: "status-json" }
  | { readonly t: "events" }
  | { readonly t: "asset"; readonly path: string }
  | { readonly t: "index" }
  | { readonly t: "not-found" }

export function parseStatusServerRoute(url: unknown): ParsedStatusServerRoute {
  if (typeof url !== "string" && url !== undefined) return { t: "not-found" }
  const rawPath = (url ?? "/").split(/[?#]/, 1)[0] ?? "/"
  const rawDecoded = decodePathname(rawPath)
  if (rawDecoded === undefined || rawDecoded.includes("\u0000") || rawDecoded.includes("\\") || rawDecoded.split("/").includes("..")) return { t: "not-found" }
  let pathname: string
  try {
    pathname = new URL(url ?? "/", "http://localhost").pathname
  } catch {
    return { t: "not-found" }
  }
  if (pathname === "/status.json") return { t: "status-json" }
  if (pathname === "/events") return { t: "events" }
  if (pathname.startsWith("/status.json/") || pathname.startsWith("/events/") || pathname.startsWith("/api/")) return { t: "not-found" }

  const decoded = decodePathname(pathname)
  if (decoded === undefined) return { t: "not-found" }
  if (decoded.includes("\u0000") || decoded.includes("\\") || decoded.split("/").includes("..")) return { t: "not-found" }
  if (decoded === "/" || decoded === "") return { t: "index" }

  const assetPath = decoded.replace(/^\/+/, "")
  const lastSegment = assetPath.split("/").at(-1) ?? ""
  if (lastSegment.includes(".")) return { t: "asset", path: assetPath }
  return { t: "index" }
}

function decodePathname(pathname: string): string | undefined {
  try {
    return decodeURIComponent(pathname)
  } catch {
    return undefined
  }
}
