ExUnit.configure(exclude: [browser_e2e: true])
ExUnit.start()

if System.get_env("CODEX_LOOPS_BROWSER_E2E") == "1" do
  {:ok, _pid} = PhoenixTest.Playwright.Supervisor.start_link()
  Application.put_env(:phoenix_test, :base_url, Workflow.Web.Endpoint.url())
end
