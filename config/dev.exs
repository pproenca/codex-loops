import Config

config :codex_loops, Workflow.Web.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4000],
  server: true,
  debug_errors: true,
  secret_key_base: String.duplicate("dev-secret-key-base-", 4)

config :logger, :console, format: "[$level] $message\n"
