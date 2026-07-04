import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { RouterProvider } from "@tanstack/react-router"
import { StrictMode } from "react"
import { createRoot } from "react-dom/client"

import { createStatusRouter } from "./routes"
import { subscribeStatus } from "./statusClient"
import "./styles.css"

const queryClient = new QueryClient()
const router = createStatusRouter(queryClient)
const unsubscribe = subscribeStatus(queryClient)

window.addEventListener("beforeunload", unsubscribe)

createRoot(document.getElementById("root") as HTMLElement).render(
  <StrictMode>
    <QueryClientProvider client={queryClient}>
      <RouterProvider router={router} />
    </QueryClientProvider>
  </StrictMode>,
)
