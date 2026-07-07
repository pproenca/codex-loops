defmodule Workflow.Web.RunLiveTest do
  @moduledoc """
  External behaviour of the live read surface, driven through a real connected
  LiveView (`Phoenix.LiveViewTest`) over the same post-commit PubSub bus the run
  writer broadcasts on. Assertions are on the rendered projection and on its
  equivalence to a pure fold of the journal — never on writer/process state.
  """
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import Plug.Conn, only: [put_req_header: 3]

  alias Workflow.{Run, Status, Journal, Event, IdempotencyKey}
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
    assert has_element?(view, "[data-testid=agents] [data-address='[2]']")
    assert has_element?(view, "[data-testid=agents] h2", "Agents (1)")
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
    assert has_element?(view, "[data-testid=agents] h2", "Agents (1)")
    assert has_element?(view, "[data-testid=agent-detail]", "Running")
    assert has_element?(view, "[data-testid=agent-detail]", "Streaming say hello")

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

    # Every rendered field is sourced from the fold — assert the render carries the
    # folded values, none invented by the LiveView process.
    rendered = render(view)
    assert has_element?(view, "[data-testid=run-header]", status.tree_name)
    assert has_element?(view, "[data-testid=phase-list]", "plan")
    assert has_element?(view, "[data-testid=agents] h2", "Agents (1)")
    assert has_element?(view, "[data-testid=result]", "result: :ok")
    assert Enum.all?(status.logs, &(rendered =~ &1))
  end

  test "reconnecting mid-run reconstructs the full view from the journal" do
    id = run_id()
    {writer, turn} = start_gated(id)

    # A brand-new LiveView (a fresh connection that never observed the earlier
    # broadcasts live) must rebuild the committed prefix purely by folding the log.
    {:ok, _view, html} = live(conn(), "/runs/#{id}")
    committed = Status.of(id)

    assert html =~ to_string(committed.state)
    assert html =~ committed.phase
    assert Enum.all?(committed.logs, &(html =~ &1))
    # The uncommitted agent turn is not shown — the view trusts the journal only.
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
    assert has_element?(view, "[data-testid=agents] h2", "Agents (1)")
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
    refute render(view) =~ ~s(data-testid="phase-agent-build-ship)

    assert has_element?(view, "[data-testid=agent-detail]", "Prompt")
    assert has_element?(view, "[data-testid=agent-detail]", "read:research")
    assert has_element?(view, "[data-testid=agent-detail]", "Activity")
    assert has_element?(view, "[data-testid=agent-detail]", "Checked research")
    assert has_element?(view, "[data-testid=agent-detail]", "Outcome")
    assert has_element?(view, "[data-testid=agent-detail]", ~s("echo" => "research"))

    view
    |> element("[data-testid=phase-item][phx-value-id=phase-1]", "build")
    |> render_click()

    assert has_element?(view, "[data-testid=phase-agents]", "build:ship")
    refute render(view) =~ ~s(data-testid="phase-agent-read-research)
    assert has_element?(view, "[data-testid=agent-detail]", "Checked ship")
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
    assert has_element?(view, "[data-testid=agent-detail]", "Rejected attempts")
    assert has_element?(view, "[data-testid=agent-detail]", "attempt 0")
    assert has_element?(view, "[data-testid=agent-detail]", "missing_required")
    assert has_element?(view, "[data-testid=agent-detail]", "Checked malformed output")
    assert has_element?(view, "[data-testid=agent-detail]", ~s("label" => "ok"))
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
    assert has_element?(view, "[data-testid=agent-detail]", "Failed")
    assert has_element?(view, "[data-testid=agent-detail]", "Rejected attempts")
    assert has_element?(view, "[data-testid=agent-detail]", "attempt 0")
    assert has_element?(view, "[data-testid=agent-detail]", "missing_required")
    assert has_element?(view, "[data-testid=agent-detail]", "No activity recorded")
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

    assert has_element?(view, "[data-testid=agent-detail]", ~s("label" => "zero"))
    assert has_element?(view, "[data-testid=agent-detail]", "first rejection")
    refute render(view) =~ "second rejection"

    view
    |> element("[data-testid=phase-agent-loop-work-i1] button")
    |> render_click()

    assert has_element?(view, "[data-testid=agent-detail]", ~s("label" => "one"))
    assert has_element?(view, "[data-testid=agent-detail]", "second rejection")
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
    assert has_element?(view, "[data-testid=agent-detail]", ~s("label" => "zero"))
    assert has_element?(view, "[data-testid=agent-detail]", "Failed attempts")
    assert has_element?(view, "[data-testid=agent-detail]", "iteration 1")
    assert has_element?(view, "[data-testid=agent-detail]", "failed iteration rejection")
    assert has_element?(view, "[data-testid=agent-detail]", ~s("bad" => 1))
    assert has_element?(view, "[data-testid=agent-detail]", "missing_required")
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
