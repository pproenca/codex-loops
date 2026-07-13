defmodule Workflow.Web.Endpoint do
  @moduledoc """
  The scheduler's supervised HTTP/WebSocket boundary. It serves the stateless
  Streamable HTTP MCP route, the JSON API, and the journal-backed
  `Workflow.Web.RunLive`; it owns no run state. Its `pubsub_server` is
  `Workflow.PubSub` — the same post-commit bus the run writer broadcasts on —
  so a connected LiveView refreshes from committed events plus scheduler-owned
  lifecycle lease facts.
  """
  use Phoenix.Endpoint, otp_app: :codex_loops

  alias Workflow.Web.LoopbackGuard

  @session_options [
    store: :cookie,
    key: "_codex_loops_key",
    signing_salt: "codex-loops-session",
    same_site: "Lax"
  ]

  socket("/live", Phoenix.LiveView.Socket,
    websocket: [
      connect_info: [session: @session_options],
      check_origin: {LoopbackGuard, :origin_allowed?, []}
    ]
  )

  plug(Plug.Static,
    at: "/assets/phoenix",
    from: {:phoenix, "priv/static"},
    only: ~w(phoenix.js)
  )

  plug(Plug.Static,
    at: "/assets/phoenix_live_view",
    from: {:phoenix_live_view, "priv/static"},
    only: ~w(phoenix_live_view.js)
  )

  plug(Plug.Static,
    at: "/assets/codex-loops",
    from: {:codex_loops, "priv/static"},
    only: ~w(run.css)
  )

  plug(LoopbackGuard)
  plug(Plug.Session, @session_options)
  plug(Workflow.Web.Router)
end
