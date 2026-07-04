import { useQuery, useQueryClient } from "@tanstack/react-query"
import { createRootRoute, createRoute, createRouter, Link, Outlet, useNavigate, useParams, type Router } from "@tanstack/react-router"
import { useEffect } from "react"
import type { QueryClient } from "@tanstack/react-query"

import { StatusApp } from "./App"
import { fetchStatus, statusQueryKey } from "./statusClient"

const rootRoute = createRootRoute({
  component: Root,
})

const indexRoute = createRoute({
  getParentRoute: () => rootRoute,
  path: "/",
  component: IndexRoute,
})

const phaseRoute = createRoute({
  getParentRoute: () => rootRoute,
  path: "/phase/$phaseIndex",
  component: PhaseRoute,
})

const agentRoute = createRoute({
  getParentRoute: () => rootRoute,
  path: "/phase/$phaseIndex/agent/$agentId",
  component: PhaseRoute,
})

const routeTree = rootRoute.addChildren([indexRoute, phaseRoute, agentRoute])

function Root() {
  return <Outlet />
}

function IndexRoute() {
  const navigate = useNavigate()
  const query = useQuery({ queryKey: statusQueryKey, queryFn: fetchStatus })

  useEffect(() => {
    if ((query.data?.status.phases.length ?? 0) > 0) {
      void navigate({ to: "/phase/$phaseIndex", params: { phaseIndex: "0" }, replace: true })
    }
  }, [navigate, query.data?.status.phases.length])

  return <StatusApp payload={query.data} phaseIndex={0} query={query} />
}

function PhaseRoute() {
  const params = useParams({ strict: false })
  const phaseIndex = Number(params.phaseIndex ?? 0)
  const agentId = typeof params.agentId === "string" ? params.agentId : undefined
  const query = useQuery({ queryKey: statusQueryKey, queryFn: fetchStatus })
  return <StatusApp payload={query.data} phaseIndex={Number.isFinite(phaseIndex) ? phaseIndex : 0} agentId={agentId} query={query} />
}

export function createStatusRouter(queryClient: QueryClient): Router<typeof routeTree> {
  return createRouter({
    routeTree,
    context: { queryClient },
    defaultPreload: "intent",
  })
}

export { Link, useQueryClient }

declare module "@tanstack/react-router" {
  interface Register {
    router: ReturnType<typeof createStatusRouter>
  }
}
