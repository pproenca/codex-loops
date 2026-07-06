import Config

# Endpoint runs without binding a port; `Phoenix.LiveViewTest` drives the LiveView
# through the endpoint in-process.
config :codex_loops, Workflow.Web.Endpoint, server: false

config :logger, level: :warning
