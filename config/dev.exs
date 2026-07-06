import Config

config :codex_loops, Workflow.Web.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4000],
  server: true,
  debug_errors: true,
  check_origin: false

config :logger, :console, format: "[$level] $message\n"
