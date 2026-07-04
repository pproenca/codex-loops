import type { QueryClient } from "@tanstack/react-query"

import { parseStatusPayload, type StatusPayload } from "./statusSchema"

export const statusQueryKey = ["status"] as const
export const statusStreamErrorQueryKey = ["status-stream-error"] as const

export async function fetchStatus(): Promise<StatusPayload> {
  const response = await fetch("/status.json", { cache: "no-store" })
  if (!response.ok) throw new Error(`Status request failed with HTTP ${response.status}`)
  const payload: unknown = await response.json()
  return parseStatusPayload(payload)
}

export function subscribeStatus(queryClient: QueryClient): () => void {
  if (typeof EventSource === "undefined") return () => {}

  const events = new EventSource("/events")
  events.onmessage = (event) => {
    try {
      const payload: unknown = JSON.parse(event.data)
      const parsed = parseStatusPayload(payload)
      queryClient.setQueryData(statusQueryKey, parsed)
      queryClient.setQueryData(statusStreamErrorQueryKey, null)
    } catch (error) {
      queryClient.setQueryData(statusStreamErrorQueryKey, error instanceof Error ? error.message : String(error))
    }
  }
  events.onerror = () => {
    queryClient.setQueryData(statusStreamErrorQueryKey, "Live updates disconnected. Retrying...")
  }
  return () => events.close()
}
