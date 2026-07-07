import Config

# Endpoint runs without binding a port; `Phoenix.LiveViewTest` drives the LiveView
# through the endpoint in-process.
config :codex_loops, Workflow.Web.Endpoint, server: false

config :codex_loops, Workflow.Journal,
  path:
    Path.join(
      System.tmp_dir!(),
      "agent_loops_test_#{System.system_time(:nanosecond)}_#{System.unique_integer([:positive])}.sqlite"
    )

config :logger, level: :warning
