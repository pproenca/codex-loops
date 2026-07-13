import Config

# The live read surface: a Phoenix endpoint whose only job is to serve the
# journal-projecting LiveView. It carries no run state; PubSub is the post-commit
# bus the LiveView subscribes to, and every render is a pure fold of the journal.
config :codex_loops, Workflow.Web.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  check_origin: :conn,
  live_view: [signing_salt: "codex-loops-live-view"],
  pubsub_server: Workflow.PubSub,
  render_errors: [formats: [html: Workflow.Web.ErrorHTML], layout: false],
  server: false

config :phoenix, :json_library, Jason

config :tailwind,
  version: "4.3.0",
  codex_loops: [
    args: ~w(--input=assets/css/run.css --output=priv/static/run.css),
    cd: Path.expand("..", __DIR__)
  ]

import_config "#{config_env()}.exs"
