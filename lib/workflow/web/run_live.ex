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

  alias Workflow.{RunInspector, Status}

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

  @impl true
  def handle_event("focus_phase", %{"id" => phase_id}, socket) do
    {:noreply, focus_phase(socket, phase_id)}
  end

  def handle_event("select_agent", %{"id" => agent_id}, socket) do
    {:noreply, select_agent(socket, agent_id)}
  end

  # The single point where state enters the socket: a fresh fold of the journal.
  defp assign_projection(socket, run_id) do
    status = Status.of(run_id)
    inspector = RunInspector.from_status(status)

    selection =
      RunInspector.selection(
        inspector,
        socket.assigns[:focused_phase_id],
        socket.assigns[:selected_agent_id]
      )

    assign(socket,
      run_id: run_id,
      status: status,
      inspector: inspector
    )
    |> assign_selection(selection)
  end

  defp focus_phase(socket, phase_id) do
    socket.assigns.inspector
    |> RunInspector.selection(phase_id, nil)
    |> then(&assign_selection(socket, &1))
  end

  defp select_agent(socket, agent_id) do
    socket.assigns.inspector
    |> RunInspector.selection(socket.assigns.focused_phase_id, agent_id)
    |> then(&assign_selection(socket, &1))
  end

  defp assign_selection(socket, %{focused_phase_id: phase_id, selected_agent_id: agent_id}) do
    assign(socket,
      focused_phase_id: phase_id,
      selected_agent_id: agent_id,
      inspector_detail: RunInspector.detail(socket.assigns.inspector, phase_id, agent_id)
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <meta name="csrf-token" content={csrf_token()} />
    <script defer src="/assets/phoenix/phoenix.js">
    </script>
    <script defer src="/assets/phoenix_live_view/phoenix_live_view.js">
    </script>
    <script defer>
      window.addEventListener("DOMContentLoaded", function () {
        var csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content");
        var liveSocket = new LiveView.LiveSocket("/live", Phoenix.Socket, {
          params: { _csrf_token: csrfToken }
        });
        liveSocket.connect();
        window.liveSocket = liveSocket;
      });
    </script>
    <style>
      :root {
        color: #171717;
        background: #f6f7f9;
        font-family:
          Inter, ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      }

      body {
        margin: 0;
        background: #f6f7f9;
      }

      #run {
        box-sizing: border-box;
        width: min(1180px, 100%);
        min-height: 100vh;
        margin: 0 auto;
        padding: 28px;
      }

      #run * {
        box-sizing: border-box;
      }

      [data-testid="run-header"] {
        display: flex;
        flex-wrap: wrap;
        align-items: flex-start;
        justify-content: space-between;
        gap: 18px 28px;
        padding-bottom: 20px;
        border-bottom: 1px solid #d8dee8;
      }

      h1,
      h2,
      h3,
      p {
        margin-top: 0;
      }

      h1 {
        display: flex;
        flex-wrap: wrap;
        gap: 8px;
        align-items: baseline;
        max-width: 520px;
        margin-bottom: 0;
        font-size: 24px;
        line-height: 1.2;
        font-weight: 760;
      }

      h2 {
        margin-bottom: 12px;
        font-size: 15px;
        line-height: 1.25;
        font-weight: 720;
      }

      h3 {
        margin-bottom: 8px;
        font-size: 12px;
        line-height: 1.25;
        font-weight: 720;
        color: #516070;
        text-transform: uppercase;
      }

      code,
      pre {
        font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
      }

      code {
        padding: 3px 7px;
        border: 1px solid #d8dee8;
        border-radius: 6px;
        background: #ffffff;
        color: #344054;
        font-size: 14px;
      }

      pre {
        max-width: 100%;
        margin: 0 0 16px;
        padding: 10px 12px;
        overflow: auto;
        border: 1px solid #d8dee8;
        border-radius: 8px;
        background: #fbfcfe;
        font-size: 12px;
        line-height: 1.45;
        white-space: pre-wrap;
        overflow-wrap: anywhere;
      }

      dl {
        display: grid;
        grid-template-columns: repeat(6, minmax(76px, 1fr));
        gap: 10px;
        min-width: min(100%, 540px);
        margin: 0;
      }

      dt {
        margin-bottom: 4px;
        color: #6b7280;
        font-size: 11px;
        font-weight: 700;
        letter-spacing: 0;
        text-transform: uppercase;
      }

      dd {
        margin: 0;
        font-size: 14px;
        font-weight: 650;
        overflow-wrap: normal;
        word-break: normal;
      }

      [data-testid="inspector"] {
        display: grid;
        grid-template-columns: 160px minmax(220px, 280px) minmax(0, 1fr);
        gap: 16px;
        align-items: start;
        margin-top: 20px;
      }

      [data-testid="phase-list"],
      [data-testid="agents"],
      [data-testid="agent-detail"],
      [data-testid="logs"],
      [data-testid="result"],
      [data-testid="failure"] {
        min-width: 0;
        border: 1px solid #d8dee8;
        border-radius: 8px;
        background: #ffffff;
        padding: 14px;
        box-shadow: 0 1px 2px rgba(16, 24, 40, 0.04);
      }

      [data-testid="phase-list"] {
        display: grid;
        gap: 8px;
      }

      button {
        width: 100%;
        min-width: 0;
        min-height: 36px;
        border: 1px solid #cfd6e2;
        border-radius: 7px;
        background: #ffffff;
        color: #1f2937;
        font: inherit;
        font-size: 13px;
        line-height: 1.25;
        text-align: left;
        overflow-wrap: normal;
        word-break: normal;
        cursor: pointer;
      }

      button:hover {
        border-color: #8fa3bd;
        background: #f8fafc;
      }

      button[aria-pressed] {
        border-color: #2563eb;
        background: #eff6ff;
        color: #1e3a8a;
        font-weight: 680;
      }

      [data-testid="phase-list"] button {
        padding: 9px 10px;
      }

      [data-testid="phase-agents"] {
        display: grid;
        gap: 8px;
        margin: 0;
        padding-left: 20px;
      }

      [data-testid="phase-agents"] li {
        padding-left: 2px;
      }

      [data-testid="phase-agents"] button {
        padding: 9px 10px;
      }

      [data-testid="agent-detail"] > section {
        margin-top: 14px;
        padding-left: 12px;
        border-left: 3px solid #d8dee8;
      }

      [data-testid="agent-detail"] ol,
      [data-testid="logs"] ul {
        margin-top: 0;
        margin-bottom: 0;
      }

      [data-testid="agent-detail"] li {
        margin-bottom: 8px;
      }

      [data-testid="agent-detail"] strong {
        display: inline-block;
        margin-right: 6px;
      }

      [data-testid="logs"],
      [data-testid="result"],
      [data-testid="failure"] {
        margin-top: 16px;
      }

      [data-testid="failure"] {
        border-color: #fecaca;
        background: #fff7f7;
        color: #991b1b;
      }

      @media (max-width: 860px) {
        #run {
          padding: 18px;
        }

        [data-testid="run-header"] {
          display: block;
        }

        h1 {
          max-width: none;
          margin-bottom: 18px;
        }

        [data-testid="inspector"] {
          grid-template-columns: 1fr;
        }

        dl {
          display: block;
          width: 100%;
          min-width: 0;
        }

        dt {
          margin: 0;
        }

        dd {
          min-width: 0;
          margin-bottom: 12px;
          overflow-wrap: normal;
          word-break: normal;
        }

        [data-testid="phase-list"] {
          grid-template-columns: repeat(2, minmax(0, 1fr));
        }

        [data-testid="phase-list"] button {
          text-align: center;
        }

        [data-testid="phase-list"],
        [data-testid="agents"],
        [data-testid="agent-detail"],
        [data-testid="logs"],
        [data-testid="result"],
        [data-testid="failure"] {
          width: 100%;
        }
      }
    </style>
    <main id="run" data-run-id={@run_id}>
      <header data-testid="run-header">
        <h1>{@status.tree_name || "Run"} <code data-testid="run-id">{@run_id}</code></h1>
        <dl>
          <dt>state</dt>
          <dd data-testid="run-state">{@status.state}</dd>
          <dt :if={@status.tree_name}>workflow</dt>
          <dd :if={@status.tree_name} data-testid="tree-name">{@status.tree_name}</dd>
          <dt :if={@status.phase}>phase</dt>
          <dd :if={@status.phase} data-testid="phase">{@status.phase}</dd>
          <dt>agents</dt>
          <dd data-testid="agent-count">{plural_count(length(@inspector.agents), "agent")}</dd>
          <dt>tokens</dt>
          <dd data-testid="usage">{@status.usage.total_tokens}</dd>
          <dt>events</dt>
          <dd data-testid="event-count">{@status.event_count}</dd>
        </dl>
      </header>

      <section data-testid="inspector">
        <nav data-testid="phase-list" aria-label="Phases">
          <button
            :for={phase <- @inspector.phases}
            type="button"
            phx-click="focus_phase"
            phx-value-id={phase.id}
            data-testid="phase-item"
            aria-pressed={phase.id == @focused_phase_id}
          >
            {phase.name} ({length(phase.agents)})
          </button>
          <p :if={@inspector.phases == []}>No phases yet</p>
        </nav>

        <section data-testid="agents">
          <% agents = @inspector_detail.agents %>
          <h2>Agents ({length(agents)})</h2>
          <ol data-testid="phase-agents">
            <li
              :for={agent <- agents}
              data-address={inspect(agent.address)}
              data-iteration={agent.iteration}
              data-testid={"phase-agent-#{agent.slug}"}
            >
              <button
                type="button"
                phx-click="select_agent"
                phx-value-id={agent.id}
                aria-pressed={agent.id == @selected_agent_id}
              >
                {agent.prompt}
              </button>
            </li>
          </ol>
        </section>

        <section data-testid="agent-detail">
          <% agent = @inspector_detail.agent %>
          <% rejections = @inspector_detail.rejected_attempts %>
          <% failed_rejections = @inspector_detail.failed_rejected_attempts %>
          <%= if agent do %>
            <h2>Agent {inspect(agent.address)}</h2>
            <p>iteration {agent.iteration}</p>
            <h3>Prompt</h3>
            <pre>{agent.prompt}</pre>
            <h3>Activity</h3>
            <ol>
              <li :for={entry <- agent.activity}>
                <strong>{entry.label}</strong>
                <span :if={entry.status}> {entry.status}</span>
                <span :if={entry.summary}> {entry.summary}</span>
              </li>
            </ol>
            <p :if={agent.activity == []}>No activity recorded</p>
            <h3>Outcome</h3>
            <pre>{inspect(agent.outcome)}</pre>
          <% else %>
            <p :if={rejections == []}>No agent selected</p>
          <% end %>
          <section :if={rejections != []} data-testid="rejected-attempts">
            <h3>Rejected attempts</h3>
            <ol>
              <li :for={rejection <- rejections}>
                <strong>attempt {rejection.attempt}</strong>
                <span> {inspect(rejection.reason)}</span>
                <pre>{inspect(rejection.output)}</pre>
                <ol :if={rejection.activity != []}>
                  <li :for={entry <- rejection.activity}>
                    <strong>{entry.label}</strong>
                    <span :if={entry.status}> {entry.status}</span>
                    <span :if={entry.summary}> {entry.summary}</span>
                  </li>
                </ol>
                <p :if={rejection.activity == []}>No activity recorded</p>
              </li>
            </ol>
          </section>
          <section :if={failed_rejections != []} data-testid="failed-attempts">
            <h3>Failed attempts</h3>
            <ol>
              <li :for={rejection <- failed_rejections}>
                <strong>iteration {rejection.iteration}, attempt {rejection.attempt}</strong>
                <span> {inspect(rejection.reason)}</span>
                <pre>{inspect(rejection.output)}</pre>
                <ol :if={rejection.activity != []}>
                  <li :for={entry <- rejection.activity}>
                    <strong>{entry.label}</strong>
                    <span :if={entry.status}> {entry.status}</span>
                    <span :if={entry.summary}> {entry.summary}</span>
                  </li>
                </ol>
                <p :if={rejection.activity == []}>No activity recorded</p>
              </li>
            </ol>
          </section>
        </section>
      </section>

      <section data-testid="logs">
        <h2>Log</h2>
        <ul>
          <li :for={line <- @status.logs}>{line}</li>
        </ul>
      </section>

      <p :if={@status.state == :completed} data-testid="result">
        result: {inspect(@status.result)}
      </p>
      <p :if={@status.state == :failed} data-testid="failure">
        failed at {inspect(@status.failure.address)}: {inspect(@status.failure.reason)}
      </p>
    </main>
    """
  end

  defp plural_count(1, word), do: "1 #{word}"
  defp plural_count(count, word), do: "#{count} #{word}s"

  defp csrf_token, do: Plug.CSRFProtection.get_csrf_token()
end
