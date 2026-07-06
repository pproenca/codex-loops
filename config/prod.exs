import Config

config :codex_loops, Workflow.Web.Endpoint,
  http: [ip: {0, 0, 0, 0}, port: {:system, "PORT"}],
  server: true

config :logger, level: :info
