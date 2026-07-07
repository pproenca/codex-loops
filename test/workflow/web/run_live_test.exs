defmodule Workflow.Web.RunLiveTest do
  @moduledoc """
  External behaviour of the live read surface, driven through a real connected
  LiveView (`Phoenix.LiveViewTest`) over the same post-commit PubSub bus the run
  writer broadcasts on. Assertions are on the rendered projection and on its
  equivalence to the scheduler snapshot: the committed journal fold plus runtime
  lease facts used only for lifecycle availability.
  """
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import Plug.Conn, only: [put_req_header: 3]

  alias Workflow.{Run, Status, Journal, Event, IdempotencyKey, Script}
  alias Workflow.Provider.Usage
  alias Workflow.Test.{EchoProvider, GateProvider}

  @endpoint Workflow.Web.Endpoint

  defmodule DemoWorkflow do
    use Workflow

    workflow "demo" do
      phase("plan")
      log("starting up")
      agent("say hello")
      return(:ok)
    end
  end

  defmodule InspectorWorkflow do
    use Workflow

    workflow "inspector-demo" do
      phase("plan")
      agent("research", label: "read:research")
      phase("build")
      agent("ship", label: "build:ship")
      return(:ok)
    end
  end

  defmodule PhaseTransitionWorkflow do
    use Workflow

    workflow "phase-transition-demo" do
      phase("draft")
      agent("first-agent", label: "draft:first")
      phase("ship")
      agent("second-agent", label: "ship:second")
      return(:ok)
    end
  end

  defmodule LogHeavyWorkflow do
    use Workflow

    workflow "log-heavy-demo" do
      phase("observe")
      log("event one")
      log("event two")
      log("event three")
      log("event four")
      log("event five")
      return(:ok)
    end
  end

  defmodule RetryWorkflow do
    use Workflow

    workflow "retry-demo" do
      phase("validate")

      agent("classify",
        schema: %{
          "type" => "object",
          "properties" => %{"label" => %{"type" => "string"}},
          "required" => ["label"]
        },
        retries: 1
      )

      return(:ok)
    end
  end

  defmodule LongRetryWorkflow do
    use Workflow

    workflow "long-retry-demo" do
      phase("validate")

      agent("classify long",
        label: "classify:long",
        schema: %{
          "type" => "object",
          "properties" => %{"label" => %{"type" => "string"}},
          "required" => ["label"]
        },
        retries: 2
      )

      return(:ok)
    end
  end

  defmodule FailureWorkflow do
    use Workflow

    workflow "failure-demo" do
      phase("validate")

      agent("classify",
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

  defmodule ActivityProvider do
    @behaviour Workflow.Provider

    alias Workflow.Provider.Usage

    @impl true
    def run_agent(prompt, _schema, _key, opts) do
      if sink = Keyword.get(opts, :sink), do: send(sink, {:agent_called, prompt})

      activity = [
        %{
          kind: "reasoning",
          label: "Reasoning",
          summary: "Checked #{prompt}",
          status: "completed"
        }
      ]

      {:ok, %{"echo" => prompt}, %Usage{input_tokens: 1, output_tokens: 1, total_tokens: 2},
       activity}
    end
  end

  defmodule StreamingGateProvider do
    @behaviour Workflow.Provider

    alias Workflow.Provider.Usage

    @impl true
    def run_agent(prompt, _schema, _key, opts) do
      sink = Keyword.fetch!(opts, :sink)
      activity_sink = Keyword.fetch!(opts, :activity_sink)

      activity_sink.(%{
        kind: "lifecycle",
        label: "Turn started",
        summary: "Streaming #{prompt}",
        status: "running"
      })

      send(sink, {:at_agent, self()})

      receive do: (:proceed -> :ok)

      {:ok, %{"echo" => prompt}, %Usage{input_tokens: 1, output_tokens: 1, total_tokens: 2},
       [
         %{
           kind: "reasoning",
           label: "Reasoning",
           summary: "Finished #{prompt}",
           status: "completed"
         }
       ]}
    end
  end

  defmodule RetryActivityProvider do
    @behaviour Workflow.Provider

    alias Workflow.Provider.Usage

    @impl true
    def run_agent(prompt, _schema, key, opts) do
      if sink = Keyword.get(opts, :sink), do: send(sink, {:agent_called, prompt, key.attempt})

      case Keyword.fetch!(opts, :mode) do
        :retry ->
          retry_result(key.attempt)

        :retry_twice_long ->
          retry_twice_long_result(key.attempt)

        :fail ->
          {:ok, %{"bad" => true}, %Usage{input_tokens: 1, output_tokens: 1, total_tokens: 2}, []}
      end
    end

    defp retry_result(0) do
      activity = [
        %{
          kind: "tool",
          label: "Validator",
          summary: "Checked malformed output",
          status: "rejected"
        }
      ]

      {:ok, %{"bad" => true}, %Usage{input_tokens: 1, output_tokens: 1, total_tokens: 2},
       activity}
    end

    defp retry_result(_attempt) do
      {:ok, %{"label" => "ok"}, %Usage{input_tokens: 1, output_tokens: 1, total_tokens: 2}, []}
    end

    defp retry_twice_long_result(attempt) when attempt in [0, 1] do
      {:ok, %{"bad" => attempt}, %Usage{input_tokens: 1, output_tokens: 1, total_tokens: 2},
       [
         %{
           kind: "tool",
           label: "Validator",
           summary: "Rejected malformed output #{attempt}",
           status: "rejected"
         }
       ]}
    end

    defp retry_twice_long_result(_attempt) do
      long_summary =
        "Recorded " <> String.duplicate("activity detail ", 16) <> "visible-tail"

      {:ok, %{"label" => "ok"}, %Usage{input_tokens: 1, output_tokens: 1, total_tokens: 2},
       [
         %{
           kind: "reasoning",
           label: "Reasoning",
           summary: long_summary,
           status: "completed"
         }
       ]}
    end
  end

  defp run_id, do: "run_#{System.unique_integer([:positive])}"
  defp conn, do: Phoenix.ConnTest.build_conn()

  defp write_script(source, prefix \\ "wf") do
    dir = Path.join(System.tmp_dir!(), "agent_loops_run_live_test")
    File.mkdir_p!(dir)
    path = Path.join(dir, "#{prefix}_#{System.unique_integer([:positive])}.exs")
    File.write!(path, source)
    path
  end

  defp write_workflow(block) do
    mod = "RunLiveAPIFixture#{System.unique_integer([:positive])}"

    source = """
    defmodule #{mod} do
      use Workflow
      #{block}
    end
    """

    write_script(source)
  end

  defp api_workflow do
    write_workflow(~S"""
    workflow "live-api-demo" do
      phase "draft"
      log "api-started"
      agent "ship it"
      return :ok
    end
    """)
  end

  defp json_conn do
    conn()
    |> put_req_header("accept", "application/json")
  end

  defp post_json(conn, path, body) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(path, Jason.encode!(body))
  end

  defp append_event(run_id, seq, %Event{} = event) do
    :ok = Journal.append(run_id, seq, %{event | run_id: run_id, seq: seq})
  end

  defp wait_for_render(view, text, attempts \\ 50)

  defp wait_for_render(view, text, 0),
    do: flunk("expected LiveView render to include #{inspect(text)}, got: #{render(view)}")

  defp wait_for_render(view, text, attempts) do
    html = render(view)

    if html =~ text do
      html
    else
      Process.sleep(10)
      wait_for_render(view, text, attempts - 1)
    end
  end

  # Start a run whose single agent turn blocks inside the provider, then wait until
  # the writer is parked there. At that point run_started/phase_entered/log_emitted
  # are committed but agent_committed/run_completed are not — a deterministic
  # "mid-run" journal state. Returns the writer pid and the gated turn's pid.
  defp start_gated(id) do
    {:ok, ^id, writer} =
      Run.start(DemoWorkflow, run_id: id, provider: {GateProvider, sink: self()})

    assert_receive {:at_agent, turn}
    {writer, turn}
  end

  defp finish(writer, turn) do
    ref = Process.monitor(writer)
    send(turn, :proceed)
    assert_receive {:DOWN, ^ref, :process, ^writer, :normal}
  end

  defp await_lease_released(run_id, tries \\ 200) do
    cond do
      Registry.lookup(Workflow.Run.Registry, run_id) == [] ->
        :ok

      tries == 0 ->
        flunk("lease for #{run_id} was never released")

      true ->
        Process.sleep(5)
        await_lease_released(run_id, tries - 1)
    end
  end

  defp kill_and_await(run_id, pid) do
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
    await_lease_released(run_id)
  end

  defp assert_in_order(rendered, snippets) do
    snippets
    |> Enum.reduce(-1, fn snippet, previous_index ->
      index =
        case :binary.match(rendered, snippet) do
          {index, _length} -> index
          :nomatch -> flunk("expected #{inspect(snippet)} in #{rendered}")
        end

      assert index > previous_index
      index
    end)
  end

  defp refute_details_open(rendered, test_id) do
    assert rendered =~ ~s(<details data-testid="#{test_id}")
    refute rendered =~ ~s(<details data-testid="#{test_id}" open)
  end

  defp list_item_count(rendered), do: ~r/<li(?:\s|>)/ |> Regex.scan(rendered) |> length()

  defp inline_style(rendered) do
    [_, style] = Regex.run(~r/<style>(?<style>.*?)<\/style>/s, rendered)
    style
  end

  defp css_rule(css, selector) do
    selector = Regex.escape(selector)
    [_, body] = Regex.run(~r/(?:^|\n)\s*#{selector}\s*\{(?<body>.*?)\}/s, css)
    body
  end

  test "status strip leads with scheduler-derived lifecycle action and hides pause" do
    id = run_id()
    {writer, turn} = start_gated(id)

    {:ok, view, _html} = live(conn(), "/runs/#{id}")

    strip = view |> element("[data-testid=status-strip]") |> render()

    assert_in_order(strip, [
      ~s(data-testid="run-state"),
      ~s(data-testid="run-phase"),
      ~s(data-testid="lifecycle-action"),
      ~s(data-testid="run-counters"),
      ~s(data-testid="run-id")
    ])

    assert strip =~ "running"
    assert strip =~ "plan"
    assert strip =~ "Pause unavailable"
    assert strip =~ ~s(aria-disabled="true")
    refute strip =~ ~s(phx-click="resume_run")
    refute strip =~ ~r/<button[^>]*>\s*Pause\s*</

    finish(writer, turn)
    wait_for_render(view, "result: :ok")

    completed_strip = view |> element("[data-testid=status-strip]") |> render()
    assert completed_strip =~ "No lifecycle action"
    refute completed_strip =~ "Resume"

    recoverable_id = run_id()
    path = api_workflow()
    {:ok, tree} = Script.load_tree(path)

    {:ok, ^recoverable_id, recoverable_writer} =
      Run.start(tree,
        run_id: recoverable_id,
        provider: {GateProvider, sink: self()},
        script_path: path
      )

    assert_receive {:at_agent, _recoverable_turn}
    kill_and_await(recoverable_id, recoverable_writer)

    {:ok, recoverable_view, _html} = live(conn(), "/runs/#{recoverable_id}")

    assert has_element?(
             recoverable_view,
             "[data-testid=lifecycle-action][data-action=resume]",
             "Resume"
           )

    recoverable_strip = recoverable_view |> element("[data-testid=status-strip]") |> render()
    assert recoverable_strip =~ ~s(data-method="post")
    assert recoverable_strip =~ ~s(data-href="/api/runs/#{recoverable_id}/resume")
    refute recoverable_strip =~ ~s(phx-click="resume_run")
  end

  test "status strip renders resume unavailable when an incomplete run has no script path" do
    id = run_id()
    path = api_workflow()
    {:ok, tree} = Script.load_tree(path)

    {:ok, ^id, writer} =
      Run.start(tree,
        run_id: id,
        provider: {GateProvider, sink: self()}
      )

    assert_receive {:at_agent, ^writer}
    kill_and_await(id, writer)

    {:ok, view, _html} = live(conn(), "/runs/#{id}")

    assert has_element?(
             view,
             "[data-testid=lifecycle-action][data-action=resume_unavailable][aria-disabled=true]",
             "Resume unavailable"
           )

    strip = view |> element("[data-testid=status-strip]") |> render()
    assert strip =~ "No journaled script path is available."
    refute strip =~ ~s(data-action="resume")
    refute strip =~ ~s(data-method="post")
  end

  test "starting a run streams live updates to a connected LiveView as events commit" do
    id = run_id()
    {writer, turn} = start_gated(id)

    # Mounted mid-run: the initial projection already reflects the committed prefix.
    {:ok, view, html} = live(conn(), "/runs/#{id}")
    assert html =~ "running"
    assert html =~ "plan"
    assert html =~ "starting up"
    refute has_element?(view, "[data-testid=result]")

    # Let the run finish; the writer commits agent_committed + run_completed and
    # broadcasts each. The already-mounted view re-folds and reflects them live —
    # no remount.
    finish(writer, turn)

    updated = render(view)
    assert updated =~ "completed"
    assert updated =~ "result: :ok"
    # The committed agent turn (address [2]) now appears; usage folds to 2 tokens.
    assert has_element?(view, "[data-testid=phase-timeline] [data-address='[2]']")
    assert has_element?(view, "[data-testid=phase-timeline]", "say hello")
  end

  test "in-flight provider activity is journaled and visible before the agent commits" do
    id = run_id()

    {:ok, ^id, writer} =
      Run.start(DemoWorkflow,
        run_id: id,
        provider: {StreamingGateProvider, sink: self()}
      )

    assert_receive {:at_agent, turn}

    {:ok, view, html} = live(conn(), "/runs/#{id}")

    assert html =~ "running"
    assert has_element?(view, "[data-testid=phase-timeline]", "say hello")
    assert has_element?(view, "[data-testid=agent-detail]", "Running")
    assert has_element?(view, "[data-testid=agent-detail]", "Streaming say hello")

    detail = view |> element("[data-testid=agent-detail]") |> render()

    assert_in_order(detail, [
      "Execution state",
      "Running",
      "Latest event",
      "Streaming say hello",
      "Prompt preview"
    ])

    assert detail =~ "No retry activity"
    refute_details_open(detail, "prompt-preview")
    refute_details_open(detail, "raw-activity")

    finish(writer, turn)

    updated = wait_for_render(view, "result: :ok")
    assert updated =~ "Finished say hello"
    assert has_element?(view, "[data-testid=agent-detail]", "Completed")
  end

  test "the rendered state equals a fold of the journal at every point" do
    id = run_id()
    assert {:ok, ^id} = Run.run(DemoWorkflow, run_id: id, provider: {EchoProvider, sink: self()})

    {:ok, view, _html} = live(conn(), "/runs/#{id}")
    status = Status.of(id)

    # Every workflow-body field is sourced from the fold; lifecycle availability is
    # carried by the scheduler snapshot rather than invented by the LiveView process.
    rendered = render(view)
    assert has_element?(view, "[data-testid=run-header]", status.tree_name)
    assert has_element?(view, "[data-testid=phase-list]", "plan")
    assert has_element?(view, "[data-testid=phase-timeline] [data-address='[2]']")
    assert has_element?(view, "[data-testid=result]", "result: :ok")
    assert Enum.all?(status.logs, &(rendered =~ &1))
    refute_details_open(rendered, "logs")
  end

  test "default monitoring view caps recent events and keeps full logs intentional" do
    id = run_id()

    assert {:ok, ^id} =
             Run.run(LogHeavyWorkflow, run_id: id, provider: {EchoProvider, sink: self()})

    {:ok, view, _html} = live(conn(), "/runs/#{id}")

    recent = view |> element("[data-testid=recent-events]") |> render()

    assert recent =~ "Recent events"
    assert recent =~ "event three"
    assert recent =~ "event four"
    assert recent =~ "event five"
    refute recent =~ "event one"
    refute recent =~ "event two"
    assert list_item_count(recent) == 3

    logs = view |> element("[data-testid=logs]") |> render()

    refute_details_open(logs, "logs")
    assert logs =~ "View logs"
    assert logs =~ "5 entries"
    assert Enum.all?(Status.of(id).logs, &(logs =~ &1))
    assert list_item_count(logs) == 5
  end

  test "monitoring polish CSS keeps status accessible and motion quiet" do
    id = run_id()

    assert {:ok, ^id} = Run.run(DemoWorkflow, run_id: id, provider: {EchoProvider, sink: self()})

    html =
      conn()
      |> get("/runs/#{id}")
      |> html_response(200)

    css = inline_style(html)

    assert css =~ ~s(.status-dot)
    assert html =~ ~s(<span class="status-dot")
    assert html =~ ~s(Status: Completed)

    assert css =~ ~s|@media (hover: hover) and (pointer: fine)|
    hover_media_index = :binary.match(css, "@media (hover: hover) and (pointer: fine)") |> elem(0)
    button_hover_index = :binary.match(css, "button:hover") |> elem(0)
    assert button_hover_index > hover_media_index

    button_rule = css_rule(css, "button")
    assert button_rule =~ "transition: transform 140ms"
    refute button_rule =~ "background-color 140ms"
    refute button_rule =~ "border-color 140ms"

    assert css =~ "@media (prefers-reduced-motion: reduce)"
    refute css =~ "@keyframes"
    refute css =~ ~r/(^|[^\w-])animation\s*:/
    refute css =~ "data-changed"
    refute css =~ "changed-row"
  end

  test "reconnecting mid-run reconstructs the full view from the journal" do
    id = run_id()
    {writer, turn} = start_gated(id)

    # A brand-new LiveView (a fresh connection that never observed the earlier
    # broadcasts live) must rebuild the committed prefix from the scheduler snapshot.
    {:ok, _view, html} = live(conn(), "/runs/#{id}")
    committed = Status.of(id)

    assert html =~ to_string(committed.state)
    assert html =~ committed.phase
    assert Enum.all?(committed.logs, &(html =~ &1))
    # The uncommitted agent turn is not shown; workflow-body state trusts committed
    # journal events only.
    assert committed.agents == []
    refute html =~ ~s({"echo")

    finish(writer, turn)

    # After completion, another fresh reconnect rebuilds the terminal state too.
    {:ok, _view2, html2} = live(conn(), "/runs/#{id}")
    assert html2 =~ "completed"
    assert length(Journal.fold(id)) == 5
  end

  test "a connected LiveView updates when the scheduler API starts a mock run" do
    id = run_id()
    path = api_workflow()

    {:ok, view, html} = live(conn(), "/runs/#{id}")
    view_pid = view.pid

    assert html =~ "pending"
    refute html =~ "api-started"

    conn =
      json_conn()
      |> post_json("/api/runs", %{script_path: path, run_id: id, provider: "mock"})

    assert %{
             "api_version" => "scheduler.v1",
             "data" => %{"run_id" => ^id, "state" => "accepted"}
           } = json_response(conn, 200)

    updated = wait_for_render(view, "result: :ok")

    assert view.pid == view_pid
    assert Process.alive?(view_pid)
    assert updated =~ "live-api-demo"
    assert updated =~ "draft"
    assert updated =~ "api-started"
    assert has_element?(view, "[data-testid=phase-timeline]", "ship it")
  end

  test "serves the browser LiveView client for inspector controls" do
    id = run_id()

    assert {:ok, ^id} = Run.run(DemoWorkflow, run_id: id, provider: {EchoProvider, sink: self()})

    html =
      conn()
      |> get("/runs/#{id}")
      |> html_response(200)

    assert html =~ ~s(<meta name="csrf-token")
    assert html =~ ~s(src="/assets/phoenix/phoenix.js")
    assert html =~ ~s(src="/assets/phoenix_live_view/phoenix_live_view.js")
    assert html =~ ~s(new LiveView.LiveSocket("/live", Phoenix.Socket)
  end

  test "renders a compact phase-focused run inspector with selected agent activity" do
    id = run_id()

    assert {:ok, ^id} =
             Run.run(InspectorWorkflow, run_id: id, provider: {ActivityProvider, sink: self()})

    {:ok, view, _html} = live(conn(), "/runs/#{id}")

    assert has_element?(view, "[data-testid=run-header]", "inspector-demo")
    assert has_element?(view, "[data-testid=phase-list]", "plan")
    assert has_element?(view, "[data-testid=phase-list]", "build")
    assert has_element?(view, "[data-testid=phase-agents]", "read:research")
    refute render(view) =~ ~s(<ol data-testid="phase-agents")
    assert has_element?(view, "[data-testid=phase-agents]", "build:ship")

    detail = view |> element("[data-testid=agent-detail]") |> render()

    assert_in_order(detail, [
      "Execution state",
      "Completed",
      "Selected agent",
      "build:ship",
      "Latest event",
      "Checked ship",
      "Final outcome",
      ~s(&quot;echo&quot; =&gt; &quot;ship&quot;),
      "Prompt preview",
      "Raw activity"
    ])

    refute_details_open(detail, "prompt-preview")
    refute_details_open(detail, "raw-activity")
    refute_details_open(detail, "raw-output")
    assert detail =~ "No retry activity"

    assert has_element?(view, "[data-testid=agent-detail]", "build:ship")

    view
    |> element("[data-testid=phase-item][phx-value-id=phase-0]", "plan")
    |> render_click()

    assert has_element?(view, "[data-testid=phase-agents]", "read:research")
    assert has_element?(view, "[data-testid=phase-agents]", "build:ship")
    assert has_element?(view, "[data-testid=agent-detail]", "Checked research")
  end

  test "renders a nested phase and agent monitoring timeline with current work expanded" do
    id = run_id()

    assert {:ok, ^id} =
             Run.run(InspectorWorkflow, run_id: id, provider: {ActivityProvider, sink: self()})

    {:ok, view, _html} = live(conn(), "/runs/#{id}")

    assert has_element?(
             view,
             "[data-testid=phase-timeline] [data-testid=phase-row][data-phase-id=phase-1][data-expanded=true]",
             "build"
           )

    assert has_element?(
             view,
             "[data-testid=phase-timeline] [data-testid=phase-row][data-phase-id=phase-0][data-expanded=false]",
             "plan"
           )

    assert has_element?(
             view,
             "[data-testid=phase-row][data-phase-id=phase-0] [data-testid=phase-agent-read-research-i0]",
             "read:research"
           )

    assert has_element?(
             view,
             "[data-testid=phase-row][data-phase-id=phase-1] [data-testid=phase-agent-build-ship-i0]",
             "build:ship"
           )

    assert has_element?(view, "[data-testid=agent-detail]", "Checked ship")
    refute render(view) =~ ~s(data-testid="agents")

    view
    |> element("[data-testid=phase-agent-read-research-i0] button")
    |> render_click()

    assert has_element?(
             view,
             "[data-testid=phase-row][data-phase-id=phase-0][data-expanded=true]"
           )

    assert has_element?(view, "[data-testid=agent-detail]", "Checked research")
  end

  test "live refresh follows current phase until the user explicitly focuses a phase" do
    id = run_id()

    {:ok, ^id, writer} =
      Run.start(PhaseTransitionWorkflow, run_id: id, provider: {GateProvider, sink: self()})

    assert_receive {:agent_called, "first-agent"}
    assert_receive {:at_agent, first_turn}

    {:ok, view, _html} = live(conn(), "/runs/#{id}")

    assert has_element?(
             view,
             "[data-testid=phase-row][data-phase-id=phase-0][data-expanded=true]"
           )

    send(first_turn, :proceed)
    assert_receive {:agent_called, "second-agent"}
    assert_receive {:at_agent, second_turn}
    wait_for_render(view, "ship")

    assert has_element?(
             view,
             "[data-testid=phase-row][data-phase-id=phase-1][data-expanded=true]"
           )

    assert has_element?(
             view,
             "[data-testid=phase-item][phx-value-id=phase-1][aria-expanded=true]"
           )

    assert has_element?(
             view,
             "[data-testid=phase-item][phx-value-id=phase-0][aria-expanded=false]"
           )

    view
    |> element("[data-testid=phase-item][phx-value-id=phase-0]", "draft")
    |> render_click()

    assert has_element?(
             view,
             "[data-testid=phase-row][data-phase-id=phase-0][data-expanded=true]"
           )

    ref = Process.monitor(writer)
    send(second_turn, :proceed)
    assert_receive {:DOWN, ^ref, :process, ^writer, :normal}
    wait_for_render(view, "result: :ok")

    assert has_element?(
             view,
             "[data-testid=phase-row][data-phase-id=phase-0][data-expanded=true]"
           )
  end

  test "selecting an inactive agent keeps the active running agent visible in the detail pane" do
    id = run_id()

    {:ok, ^id, writer} =
      Run.start(PhaseTransitionWorkflow,
        run_id: id,
        provider: {StreamingGateProvider, sink: self()}
      )

    assert_receive {:at_agent, first_turn}
    send(first_turn, :proceed)
    assert_receive {:at_agent, second_turn}

    {:ok, view, _html} = live(conn(), "/runs/#{id}")
    wait_for_render(view, "ship")

    view
    |> element("[data-testid=phase-agent-draft-first-i0] button")
    |> render_click()

    detail = view |> element("[data-testid=agent-detail]") |> render()

    assert_in_order(detail, [
      "Execution state",
      "Completed",
      "draft:first",
      "Active now",
      "ship:second",
      "Running"
    ])

    ref = Process.monitor(writer)
    send(second_turn, :proceed)
    assert_receive {:DOWN, ^ref, :process, ^writer, :normal}
  end

  test "collapsed phases render compressed summaries instead of full agent rows" do
    id = run_id()

    assert {:ok, ^id} =
             Run.run(InspectorWorkflow, run_id: id, provider: {ActivityProvider, sink: self()})

    {:ok, view, _html} = live(conn(), "/runs/#{id}")

    collapsed =
      view
      |> element("[data-testid=phase-row][data-phase-id=phase-0]")
      |> render()

    assert collapsed =~ ~s(data-expanded="false")
    assert collapsed =~ ~s(aria-expanded="false")
    assert collapsed =~ ~s(aria-controls="phase-agents-phase-0")
    assert collapsed =~ "plan"
    assert collapsed =~ "1/1"
    assert collapsed =~ "read:research"
    assert collapsed =~ "Completed"
    refute collapsed =~ ~s(class="agent-row")
    refute collapsed =~ ~s(class="agent-chip")
    refute collapsed =~ ~s(data-testid="agent-activity")
    refute collapsed =~ "Checked research"

    expanded =
      view
      |> element("[data-testid=phase-row][data-phase-id=phase-1]")
      |> render()

    assert expanded =~ ~s(data-expanded="true")
    assert expanded =~ ~s(class="agent-row")
    assert expanded =~ ~s(data-testid="agent-activity")
    assert expanded =~ "Checked ship"
  end

  test "expanded compact agent rows expose status, retry markers, and capped activity" do
    id = run_id()

    assert {:ok, ^id} =
             Run.run(LongRetryWorkflow,
               run_id: id,
               provider: {RetryActivityProvider, sink: self(), mode: :retry_twice_long}
             )

    {:ok, view, _html} = live(conn(), "/runs/#{id}")

    row =
      view
      |> element("[data-testid=phase-agent-classify-long-i0]")
      |> render()

    assert row =~ "Status: Completed"
    assert row =~ "2 retries"
    refute row =~ "2 retrys"
    assert row =~ ~s(class="agent-activity-line")
    assert row =~ "Reasoning"
    assert row =~ "..."
  end

  test "selected agent detail shows rejected retry attempts with reason and activity" do
    id = run_id()

    assert {:ok, ^id} =
             Run.run(RetryWorkflow,
               run_id: id,
               provider: {RetryActivityProvider, sink: self(), mode: :retry}
             )

    {:ok, view, _html} = live(conn(), "/runs/#{id}")

    assert has_element?(view, "[data-testid=agent-detail]", "classify")

    detail = view |> element("[data-testid=agent-detail]") |> render()

    assert_in_order(detail, [
      "Execution state",
      "Completed",
      "Latest event",
      "Completed with final outcome",
      "Retry context",
      "1 rejected attempt",
      "Final outcome",
      ~s(&quot;label&quot; =&gt; &quot;ok&quot;),
      "Retry history",
      "Checked malformed output"
    ])

    assert detail =~ "attempt 0"
    assert detail =~ "missing_required"
    refute_details_open(detail, "retry-history")
    refute_details_open(detail, "raw-output")
  end

  test "failed runs without a committed agent still render rejected attempt and failure info" do
    id = run_id()

    assert {:error, {:malformed_output, [1], {:missing_required, "label"}}} =
             Run.run(FailureWorkflow,
               run_id: id,
               provider: {RetryActivityProvider, sink: self(), mode: :fail}
             )

    {:ok, view, _html} = live(conn(), "/runs/#{id}")

    assert has_element?(view, "[data-testid=phase-list] [data-status=failed]", "validate")
    assert has_element?(view, "[data-testid=phase-agents]", "classify")

    detail = view |> element("[data-testid=agent-detail]") |> render()

    assert_in_order(detail, [
      "Execution state",
      "Failed",
      "Latest event",
      "missing_required",
      "Retry context",
      "1 rejected attempt",
      "Final outcome",
      "No final outcome",
      "Retry history"
    ])

    assert detail =~ "attempt 0"
    assert detail =~ "No activity recorded"
    refute_details_open(detail, "retry-history")

    assert has_element?(view, "[data-testid=failure]", "failed at [1]")
    assert has_element?(view, "[data-testid=failure]", "missing_required")
  end

  test "same-address loop agents are selectable by iteration and keep rejections separate" do
    id = run_id()
    usage = %Usage{input_tokens: 1, output_tokens: 1, total_tokens: 2}
    node = %Workflow.Node.Agent{address: [1], prompt: "loop work"}

    append_event(id, 0, Event.phase_entered(%Workflow.Node.Phase{address: [0], name: "loop"}))

    append_event(
      id,
      1,
      Event.agent_attempt_rejected(
        node,
        0,
        0,
        %{"bad" => 0},
        {:missing_required, "label"},
        usage,
        [%{kind: "tool", label: "Validator", summary: "first rejection", status: "rejected"}]
      )
    )

    append_event(
      id,
      2,
      Event.agent_committed(
        node,
        0,
        %IdempotencyKey{run_id: id, node_path: [1], iteration: 0},
        %{"label" => "zero"},
        usage
      )
    )

    append_event(
      id,
      3,
      Event.agent_attempt_rejected(
        node,
        1,
        0,
        %{"bad" => 1},
        {:missing_required, "label"},
        usage,
        [%{kind: "tool", label: "Validator", summary: "second rejection", status: "rejected"}]
      )
    )

    append_event(
      id,
      4,
      Event.agent_committed(
        node,
        1,
        %IdempotencyKey{run_id: id, node_path: [1], iteration: 1},
        %{"label" => "one"},
        usage
      )
    )

    {:ok, view, _html} = live(conn(), "/runs/#{id}")

    assert has_element?(view, "[data-testid=phase-agent-loop-work-i0]")
    assert has_element?(view, "[data-testid=phase-agent-loop-work-i1]")
    assert render(view) =~ ~s(phx-value-id="agent-1-i0")
    assert render(view) =~ ~s(phx-value-id="agent-1-i1")

    detail = view |> element("[data-testid=agent-detail]") |> render()

    assert_in_order(detail, [
      "Execution state",
      "iteration 0",
      "Latest event",
      "Completed with final outcome",
      "Final outcome",
      ~s(&quot;label&quot; =&gt; &quot;zero&quot;),
      "Retry history",
      "first rejection"
    ])

    refute render(view) =~ "second rejection"

    view
    |> element("[data-testid=phase-agent-loop-work-i1] button")
    |> render_click()

    selected_iteration = view |> element("[data-testid=agent-detail]") |> render()

    assert_in_order(selected_iteration, [
      "Execution state",
      "iteration 1",
      "Latest event",
      "Completed with final outcome",
      "Final outcome",
      ~s(&quot;label&quot; =&gt; &quot;one&quot;),
      "Retry history",
      "second rejection"
    ])

    refute render(view) =~ "first rejection"
  end

  test "failed rejected-only loop iteration remains visible while committed iteration is selected" do
    id = run_id()
    usage = %Usage{input_tokens: 1, output_tokens: 1, total_tokens: 2}
    node = %Workflow.Node.Agent{address: [1], prompt: "loop work"}

    append_event(id, 0, Event.phase_entered(%Workflow.Node.Phase{address: [0], name: "loop"}))

    append_event(
      id,
      1,
      Event.agent_committed(
        node,
        0,
        %IdempotencyKey{run_id: id, node_path: [1], iteration: 0},
        %{"label" => "zero"},
        usage
      )
    )

    append_event(
      id,
      2,
      Event.agent_attempt_rejected(
        node,
        1,
        0,
        %{"bad" => 1},
        {:missing_required, "label"},
        usage,
        [
          %{
            kind: "tool",
            label: "Validator",
            summary: "failed iteration rejection",
            status: "rejected"
          }
        ]
      )
    )

    append_event(
      id,
      3,
      Event.agent_failed(node, 1, 1, {:missing_required, "label"})
    )

    {:ok, view, _html} = live(conn(), "/runs/#{id}")

    assert has_element?(view, "[data-testid=phase-agent-loop-work-i0]")

    detail = view |> element("[data-testid=agent-detail]") |> render()

    assert_in_order(detail, [
      "Execution state",
      "iteration 0",
      "Latest event",
      "Completed with final outcome",
      "Retry context",
      "1 failed attempt",
      "Final outcome",
      ~s(&quot;label&quot; =&gt; &quot;zero&quot;),
      "Failed attempts",
      "iteration 1",
      "failed iteration rejection"
    ])

    assert detail =~ "failed iteration rejection"
    assert detail =~ ~s(&quot;bad&quot; =&gt; 1)
    assert detail =~ "missing_required"
    refute_details_open(detail, "failed-attempts")
  end

  test "scheduler API rejects run ids that cannot be opened by the LiveView route" do
    path = api_workflow()

    conn =
      json_conn()
      |> post_json("/api/runs", %{script_path: path, run_id: "foo/bar", provider: "mock"})

    assert %{
             "api_version" => "scheduler.v1",
             "error" => %{
               "code" => "scheduler.run.invalid_run_id",
               "details" => %{"expected" => "route_safe_non_empty_string"}
             }
           } = json_response(conn, 400)

    refute "foo/bar" in Workflow.Journal.run_ids()
  end
end
