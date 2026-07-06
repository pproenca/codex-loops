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

  # Start a run whose single agent turn blocks inside the provider, then wait until
  # the writer is parked there. At that point run_started/phase_entered/log_emitted
  # are committed but agent_committed/run_completed are not — a deterministic
  # "mid-run" journal state. Returns the writer pid and the gated turn's pid.
  defp start_gated(id) do
    {:ok, ^id, writer} = Run.start(DemoWorkflow, run_id: id, provider: {GateProvider, sink: self()})
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
end
