defmodule Workflow.Web.Endpoint do
  @moduledoc """
  The HTTP/WebSocket endpoint for the live read surface. It exists only to serve the
  scheduler-snapshot `Workflow.Web.RunLive`; it owns no run state. Its `pubsub_server`
  is `Workflow.PubSub` — the same post-commit bus the run writer broadcasts on — so a
  connected LiveView refreshes from committed events plus scheduler-owned lifecycle
  lease facts.
  """
  use Phoenix.Endpoint, otp_app: :codex_loops

  @session_options [
    store: :cookie,
    key: "_codex_loops_key",
    signing_salt: "codex-loops-session",
    same_site: "Lax"
  ]

  socket("/live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: @session_options]])

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

  plug(Plug.Session, @session_options)
  plug(Workflow.Web.Router)
end
