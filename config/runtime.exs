import Config

if config_env() == :prod do
  server? = System.get_env("CODEX_LOOPS_SERVER") in ["1", "true"]
  port = System.get_env("PORT", "4000") |> String.to_integer()

  config :codex_loops, Workflow.Web.Endpoint,
    http: [ip: {0, 0, 0, 0}, port: port],
    server: server?
end
