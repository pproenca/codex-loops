import Config

# The live read surface: a Phoenix endpoint whose only job is to serve the
# journal-projecting LiveView. It carries no run state; PubSub is the post-commit
# bus the LiveView subscribes to, and every render is a pure fold of the journal.
config :codex_loops, Workflow.Web.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  secret_key_base: "SUQJX2RiOvART1xflhyvyLScoDYg0XZCMWWKgRM9sbPN9VQELWObZMhBIELo3Q/6",
  live_view: [signing_salt: "TQN5SXrkEUE="],
  pubsub_server: Workflow.PubSub,
  render_errors: [formats: [html: Workflow.Web.ErrorHTML], layout: false],
  server: false

config :phoenix, :json_library, Jason

import_config "#{config_env()}.exs"
