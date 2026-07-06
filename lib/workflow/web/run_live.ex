defmodule Workflow.Web.RunLive do
  @moduledoc """
  A live read surface that is a **pure projection over the journal**.

  It renders `Workflow.Status.of/1` — a fold of the committed event log — and
  re-folds on every post-commit broadcast. The socket holds only the `run_id` (a
  routing key) and the derived read model; it keeps **no** run state the journal
  doesn't already contain. Consequences the design constraints demand:

    * After a writer crash it shows what was *committed*, not a process's
      uncommitted belief — because it never reads writer/process state.
    * A mid-run reconnect reconstructs the full view by folding the journal from
      scratch in `mount/3` — the initial render already reflects every prior commit.
    * The rendered state equals a fold of the journal at every point, because the
      `{:journal_committed, ...}` broadcast is treated only as a *signal to re-fold*:
      its payload is discarded and the whole read model is re-derived from the log.
      Re-folding is idempotent, so an event seen by both the initial fold and a
      later broadcast can never be double-counted.
  """
  use Phoenix.LiveView

  alias Workflow.Status

  @impl true
  def mount(%{"run_id" => run_id}, _session, socket) do
    # Subscribe before the first fold so no commit slips through the gap between
    # folding and subscribing; the idempotent re-fold absorbs any overlap.
    if connected?(socket), do: Phoenix.PubSub.subscribe(Workflow.PubSub, "run:" <> run_id)
    {:ok, assign_projection(socket, run_id)}
  end

  @impl true
  def handle_info({:journal_committed, run_id, _event}, socket) do
    {:noreply, assign_projection(socket, run_id)}
  end

  # The single point where state enters the socket: a fresh fold of the journal.
  defp assign_projection(socket, run_id) do
    assign(socket, run_id: run_id, status: Status.of(run_id))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <main id="run" data-run-id={@run_id}>
      <h1>Run <code data-testid="run-id">{@run_id}</code></h1>

      <dl>
        <dt>state</dt>
        <dd data-testid="run-state">{@status.state}</dd>
        <dt :if={@status.tree_name}>workflow</dt>
        <dd :if={@status.tree_name} data-testid="tree-name">{@status.tree_name}</dd>
        <dt :if={@status.phase}>phase</dt>
        <dd :if={@status.phase} data-testid="phase">{@status.phase}</dd>
        <dt>tokens</dt>
        <dd data-testid="usage">{@status.usage.total_tokens}</dd>
        <dt>events</dt>
        <dd data-testid="event-count">{@status.event_count}</dd>
      </dl>

      <section data-testid="logs">
        <h2>Log</h2>
        <ul>
          <li :for={line <- @status.logs}>{line}</li>
        </ul>
      </section>

      <section data-testid="agents">
        <h2>Agents ({length(@status.agents)})</h2>
        <ol>
          <li :for={agent <- @status.agents} data-address={inspect(agent.address)}>
            {inspect(agent.result)}
          </li>
        </ol>
      </section>

      <p :if={@status.state == :completed} data-testid="result">
        result: {inspect(@status.result)}
      </p>
      <p :if={@status.state == :failed} data-testid="failure">
        failed at {inspect(@status.failure.address)}: {@status.failure.reason}
      </p>
    </main>
    """
  end
end
