import Config

browser_e2e? = System.get_env("CODEX_LOOPS_BROWSER_E2E") == "1"
browser_e2e_port = "CODEX_LOOPS_BROWSER_E2E_PORT" |> System.get_env("4102") |> String.to_integer()

config :codex_loops, Workflow.Journal,
  path:
    Path.join(
      System.tmp_dir!(),
      "agent_loops_test_#{System.system_time(:nanosecond)}_#{System.unique_integer([:positive])}.sqlite"
    )

# Ordinary tests keep the endpoint in-process for Phoenix.LiveViewTest. Browser
# E2E tests opt into a bound port because Playwright drives a real browser.
config :codex_loops, Workflow.Web.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: browser_e2e_port],
  secret_key_base: String.duplicate("test-secret-key-base-", 4),
  server: browser_e2e?

config :logger, level: :warning

config :phoenix_test,
  otp_app: :codex_loops,
  playwright: [
    browser_pool: :chromium_pool,
    browser_pools: [
      [id: :chromium_pool, browser: :chromium]
    ],
    js_logger: false,
    trace: System.get_env("PW_TRACE", "false") in ~w(t true),
    screenshot: System.get_env("PW_SCREENSHOT", "false") in ~w(t true)
  ]
