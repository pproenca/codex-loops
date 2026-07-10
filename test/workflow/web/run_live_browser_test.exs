defmodule Workflow.Web.RunLiveBrowserTest do
  @moduledoc """
  Browser-level coverage for the journal-backed run UI.

  These tests are intentionally tagged out of the normal `mix test` loop and run
  only through `make browser-e2e`, where the endpoint binds a local port and
  PhoenixTest Playwright drives Chromium.
  """
  use PhoenixTest.Playwright.Case, async: false

  alias Workflow.Run
  alias Workflow.Test.EchoProvider
  alias Workflow.Test.StreamingGateProvider

  @moduletag :browser_e2e

  defmodule CompletedWorkflow do
    @moduledoc false
    use Workflow

    workflow "browser-complete" do
      phase("browser")
      log("browser smoke started")
      agent("render the completed browser smoke")
      return(:ok)
    end
  end

  defmodule FailedWorkflow do
    @moduledoc false
    use Workflow

    workflow "browser-failure" do
      phase("browser")

      agent("return malformed output",
        schema: %{
          "type" => "object",
          "properties" => %{"label" => %{"type" => "string"}},
          "required" => ["label"]
        },
        retries: 0
      )

      return(:ok)
    end
  end

  test "completed mock run is readable in a real browser", %{conn: conn} do
    id = run_id()
    assert {:ok, ^id} = Run.run(CompletedWorkflow, run_id: id, provider: {EchoProvider, sink: self()})

    conn
    |> visit("/runs/#{id}")
    |> assert_has("body .phx-connected", timeout: 2_000)
    |> assert_has("h1", text: "browser-complete")
    |> assert_has("[data-testid=run-state]", text: "completed")
    |> assert_has("[data-testid=run-phase]", text: "browser")
    |> assert_has("[data-testid=agent-detail]", text: "Completed")
    |> assert_has("[data-testid=result]", text: "Completed successfully")
  end

  test "failed mock run shows failure state and retry context in a real browser", %{conn: conn} do
    id = run_id()

    assert {:error, {:malformed_output, _address, _reason}} =
             Run.run(FailedWorkflow, run_id: id, provider: {EchoProvider, sink: self()})

    conn
    |> visit("/runs/#{id}")
    |> assert_has("body .phx-connected", timeout: 2_000)
    |> assert_has("h1", text: "browser-failure")
    |> assert_has("[data-testid=run-state]", text: "failed")
    |> assert_has("[data-testid=agent-detail]", text: "Failed")
    |> assert_has("[data-testid=agent-detail]", text: "1 rejected attempt")
    |> assert_has("[data-testid=retry-history]")
    |> assert_has("[data-testid=failure]", text: "Failed at")
  end

  test "connected browser streams in-flight activity and completion without reloading", %{conn: conn} do
    id = run_id()

    assert {:ok, ^id, writer} =
             Run.start(CompletedWorkflow,
               run_id: id,
               provider: {StreamingGateProvider, sink: self()}
             )

    assert_receive {:at_agent, ^writer}

    session =
      conn
      |> visit("/runs/#{id}")
      |> assert_has("body .phx-connected", timeout: 2_000)
      |> assert_has("[data-testid=run-state]", text: "running")
      |> assert_has("[data-testid=agent-detail]", text: "Streaming render the completed browser smoke")
      |> evaluate("window.__codexLoopsStreamingPage = true")

    send(writer, :proceed)

    session
    |> assert_has("[data-testid=run-state]", text: "completed", timeout: 2_000)
    |> assert_has("[data-testid=agent-detail]", text: "Finished render the completed browser smoke")
    |> assert_has("[data-testid=result]", text: "Completed successfully")
    |> evaluate("window.__codexLoopsStreamingPage", &assert(&1))
  end

  defp run_id, do: "browser_#{System.unique_integer([:positive])}"
end
