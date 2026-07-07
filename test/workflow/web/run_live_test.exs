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

  alias Workflow.{Run, Status, Journal}
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
    refute html =~ "completed"

    # Let the run finish; the writer commits agent_committed + run_completed and
    # broadcasts each. The already-mounted view re-folds and reflects them live —
    # no remount.
    finish(writer, turn)

    updated = render(view)
    assert updated =~ "completed"
    assert updated =~ "result: :ok"
    # The committed agent turn (address [2]) now appears; usage folds to 2 tokens.
    assert has_element?(view, "[data-testid=agents] li[data-address='[2]']")
    assert has_element?(view, "[data-testid=agents] h2", "Agents (1)")
    assert has_element?(view, "[data-testid=usage]", "2")
  end

  test "the rendered state equals a fold of the journal at every point" do
    id = run_id()
    assert {:ok, ^id} = Run.run(DemoWorkflow, run_id: id, provider: {EchoProvider, sink: self()})

    {:ok, view, _html} = live(conn(), "/runs/#{id}")
    status = Status.of(id)

    # Every rendered field is sourced from the fold — assert the render carries the
    # folded values, none invented by the LiveView process.
    rendered = render(view)
    assert has_element?(view, "[data-testid=run-state]", to_string(status.state))
    assert has_element?(view, "[data-testid=tree-name]", status.tree_name)
    assert has_element?(view, "[data-testid=phase]", status.phase)
    assert has_element?(view, "[data-testid=usage]", to_string(status.usage.total_tokens))
    assert has_element?(view, "[data-testid=event-count]", to_string(status.event_count))
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

    updated = wait_for_render(view, "completed")

    assert view.pid == view_pid
    assert Process.alive?(view_pid)
    assert updated =~ "live-api-demo"
    assert updated =~ "draft"
    assert updated =~ "api-started"
    assert has_element?(view, "[data-testid=agents] h2", "Agents (1)")
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
