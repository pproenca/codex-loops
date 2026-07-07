defmodule Workflow.Web.RunLive do
  @moduledoc """
  A live read surface over the scheduler-owned run snapshot.

  It renders a single `Workflow.Scheduler.get_run_snapshot/1` result and refreshes
  that snapshot on every post-commit broadcast. The socket holds only the `run_id`
  (a routing key) and the derived read model; it keeps **no** writer-owned run
  state. The workflow body comes from one fold of the committed event log, while
  lifecycle availability also includes scheduler-owned runtime lease facts.
  Consequences the design constraints demand:

    * After a writer crash it shows what was *committed*, not a process's
      uncommitted belief.
    * A mid-run reconnect reconstructs the full view from the scheduler snapshot
      in `mount/3` — the initial render already reflects every prior commit.
    * The `{:journal_committed, ...}` broadcast is treated only as a *signal to
      refresh*: its payload is discarded and the whole read model is re-derived.
      Refreshing is idempotent, so an event seen by both the initial snapshot and a
      later broadcast can never be double-counted.
  """
  use Phoenix.LiveView

  alias Workflow.{Scheduler, Status}

  @refresh_ms 1_000

  @impl true
  def mount(%{"run_id" => run_id}, _session, socket) do
    # Subscribe before the first fold so no commit slips through the gap between
    # folding and subscribing; the idempotent re-fold absorbs any overlap.
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Workflow.PubSub, "run:" <> run_id)
      schedule_refresh()
    end

    {:ok, assign_projection(socket, run_id)}
  end

  @impl true
  def handle_info({:journal_committed, run_id, _event}, socket) do
    {:noreply, assign_projection(socket, run_id)}
  end

  def handle_info(:refresh, socket) do
    socket = assign_projection(socket, socket.assigns.run_id)
    if socket.assigns.status.state == :running, do: schedule_refresh()
    {:noreply, socket}
  end

  @impl true
  def handle_event("focus_phase", %{"id" => phase_id}, socket) do
    {:noreply, focus_phase(socket, phase_id)}
  end

  def handle_event("select_agent", %{"id" => agent_id, "phase-id" => phase_id}, socket) do
    {:noreply, select_agent(socket, phase_id, agent_id)}
  end

  def handle_event("select_agent", %{"id" => agent_id}, socket) do
    {:noreply, select_agent(socket, socket.assigns.focused_phase_id, agent_id)}
  end

  # The single point where state enters the socket: one scheduler-owned snapshot.
  defp assign_projection(socket, run_id) do
    %{status: status, run_projection: run_projection} = scheduler_snapshot(run_id)
    user_focused_phase_id = valid_phase_id(status, socket.assigns[:user_focused_phase_id])

    phase_id =
      user_focused_phase_id ||
        valid_phase_id(status, status.current_phase_id) ||
        first_phase_id(status)

    agent_id =
      valid_agent_id(status, phase_id, socket.assigns[:selected_agent_id]) ||
        first_agent_id(status, phase_id)

    assign(socket,
      run_id: run_id,
      status: status,
      run_projection: run_projection,
      focused_phase_id: phase_id,
      user_focused_phase_id: user_focused_phase_id,
      selected_agent_id: agent_id
    )
  end

  defp scheduler_snapshot(run_id) do
    case Scheduler.get_run_snapshot(run_id) do
      {:ok, snapshot} -> snapshot
      {:error, _error} -> raise ArgumentError, "invalid run id"
    end
  end

  defp schedule_refresh, do: Process.send_after(self(), :refresh, @refresh_ms)

  defp focus_phase(socket, phase_id) do
    status = socket.assigns.status
    phase_id = valid_phase_id(status, phase_id) || first_phase_id(status)

    assign(socket,
      focused_phase_id: phase_id,
      user_focused_phase_id: phase_id,
      selected_agent_id: first_agent_id(status, phase_id)
    )
  end

  defp select_agent(socket, phase_id, agent_id) do
    status = socket.assigns.status
    phase_id = valid_phase_id(status, phase_id) || socket.assigns.focused_phase_id

    assign(socket,
      focused_phase_id: phase_id,
      user_focused_phase_id: phase_id,
      selected_agent_id:
        valid_agent_id(status, phase_id, agent_id) || first_agent_id(status, phase_id)
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
        margin-bottom: 16px;
        font-size: 24px;
        line-height: 1.2;
        font-weight: 760;
        overflow-wrap: anywhere;
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

      .status-strip {
        display: grid;
        grid-template-columns: repeat(auto-fit, minmax(min(100%, 170px), 1fr));
        gap: 10px;
        align-items: stretch;
      }

      .status-item {
        min-width: 0;
        padding: 10px 12px;
        border: 1px solid #d8dee8;
        border-radius: 8px;
        background: #ffffff;
      }

      .status-item > span,
      .status-item > label,
      .status-kicker {
        display: block;
        margin-bottom: 4px;
        color: #667085;
        font-size: 11px;
        line-height: 1.2;
        font-weight: 720;
        text-transform: uppercase;
      }

      .status-item strong {
        color: #1f2937;
        font-size: 16px;
        line-height: 1.25;
        font-weight: 760;
        overflow-wrap: anywhere;
      }

      .status-value {
        display: inline-flex;
        min-width: 0;
        align-items: center;
        gap: 7px;
      }

      .status-value > span:last-child {
        min-width: 0;
        overflow-wrap: anywhere;
      }

      .status-dot {
        flex: 0 0 auto;
        width: 8px;
        height: 8px;
        border-radius: 999px;
        background: #98a2b3;
        box-shadow: 0 0 0 2px #eef2f6;
      }

      .status-value[data-status="running"] .status-dot {
        background: #f59e0b;
        box-shadow: 0 0 0 2px #fef3c7;
      }

      .status-value[data-status="completed"] .status-dot {
        background: #16a34a;
        box-shadow: 0 0 0 2px #dcfce7;
      }

      .status-value[data-status="failed"] .status-dot {
        background: #dc2626;
        box-shadow: 0 0 0 2px #fee2e2;
      }

      .status-item small {
        display: block;
        margin-top: 4px;
        color: #667085;
        font-size: 12px;
        line-height: 1.3;
      }

      .lifecycle-button {
        width: 100%;
        min-height: 100%;
        padding: 10px 12px;
        border: 1px solid #cfd6e2;
        border-radius: 8px;
        background: #ffffff;
        color: #1f2937;
        font: inherit;
        text-align: left;
      }

      .lifecycle-button[data-enabled="true"] {
        border-color: #2563eb;
        background: #eff6ff;
        color: #1e3a8a;
      }

      .lifecycle-button[aria-disabled="true"] {
        border-color: #d8dee8;
        background: #f8fafc;
        color: #475467;
      }

      .run-counters {
        display: flex;
        flex-wrap: wrap;
        gap: 6px 10px;
        margin-top: 2px;
        color: #344054;
        font-size: 13px;
        line-height: 1.3;
        font-weight: 620;
      }

      .run-id-input {
        width: 100%;
        min-width: 0;
        border: 0;
        padding: 0;
        background: transparent;
        color: #667085;
        font: inherit;
        font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
        font-size: 13px;
        line-height: 1.3;
      }

      pre {
        max-width: 100%;
        margin: 0 0 16px;
        overflow: auto;
        font-size: 12px;
        line-height: 1.45;
        white-space: pre-wrap;
        overflow-wrap: anywhere;
      }

      .sr-only {
        position: absolute;
        width: 1px;
        height: 1px;
        padding: 0;
        overflow: hidden;
        clip: rect(0, 0, 0, 0);
        white-space: nowrap;
        border: 0;
      }
      [data-testid="inspector"] {
        display: grid;
        grid-template-columns: minmax(320px, 420px) minmax(0, 1fr);
        gap: 16px;
        align-items: start;
        margin-top: 20px;
      }

      [data-testid="phase-timeline"],
      [data-testid="phase-list"],
      [data-testid="agent-detail"],
      [data-testid="result"],
      [data-testid="failure"] {
        min-width: 0;
        border: 1px solid #d8dee8;
        border-radius: 8px;
        background: #ffffff;
        padding: 14px;
        box-shadow: 0 1px 2px rgba(16, 24, 40, 0.04);
      }

      [data-testid="phase-timeline"] {
        display: grid;
        gap: 10px;
      }

      [data-testid="phase-list"] {
        display: grid;
        gap: 10px;
        min-width: 0;
        border: 0;
        padding: 0;
        box-shadow: none;
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
        transform-origin: center;
        transition: transform 140ms cubic-bezier(0.23, 1, 0.32, 1),
          filter 140ms cubic-bezier(0.23, 1, 0.32, 1);
        -webkit-tap-highlight-color: transparent;
      }

      button:active {
        transform: scale(0.985);
        filter: brightness(0.98);
      }

      button[aria-pressed] {
        border-color: #2563eb;
        background: #eff6ff;
        color: #1e3a8a;
        font-weight: 680;
      }

      .phase-row {
        display: grid;
        gap: 8px;
        min-width: 0;
        padding: 10px;
        border: 1px solid #d8dee8;
        border-radius: 8px;
        background: #ffffff;
      }

      .phase-row[data-expanded="false"] {
        gap: 6px;
        padding: 8px 10px;
        background: #f8fafc;
      }

      .phase-row[data-status="running"] {
        border-color: #f59e0b;
      }

      .phase-row[data-status="failed"] {
        border-color: #ef4444;
        background: #fff7f7;
      }

      .phase-chip {
        display: grid;
        grid-template-columns: minmax(0, 1fr) auto;
        gap: 10px;
        align-items: center;
        min-height: 0;
        padding: 0;
        border: 0;
        background: transparent;
      }

      .phase-chip[aria-pressed="true"] {
        border: 0;
        background: transparent;
        color: #1e3a8a;
      }

      .phase-main {
        display: grid;
        gap: 2px;
        min-width: 0;
      }

      .phase-name {
        overflow: hidden;
        text-overflow: ellipsis;
        white-space: nowrap;
        font-weight: 760;
      }

      .phase-meta,
      .phase-count,
      .agent-marker {
        color: #667085;
        font-size: 12px;
        font-weight: 560;
      }

      .phase-chip[data-status="pending"] {
        border-color: #d8dee8;
        color: #667085;
      }

      .phase-chip[data-status="running"] {
        border-color: #f59e0b;
        color: #92400e;
      }

      .phase-chip[data-status="completed"] {
        border-color: #22c55e;
        color: #166534;
      }

      .phase-chip[data-status="failed"] {
        border-color: #ef4444;
        color: #991b1b;
      }

      .agent-row {
        min-width: 0;
      }

      .agent-chip[data-status="pending"] {
        border-color: #d8dee8;
        background: #f8fafc;
        color: #667085;
      }

      .agent-chip[data-status="running"] {
        border-color: #f59e0b;
        background: #fffbeb;
        color: #92400e;
      }

      .agent-chip[data-status="completed"] {
        border-color: #22c55e;
        background: #f0fdf4;
        color: #166534;
      }

      .agent-chip[data-status="failed"] {
        border-color: #ef4444;
        background: #fef2f2;
        color: #991b1b;
      }

      [data-testid="phase-agents"] {
        display: grid;
        gap: 7px;
        margin: 0;
        padding-left: 0;
      }

      .phase-row[data-expanded="false"] [data-testid="phase-agents"] {
        gap: 5px;
      }

      [data-testid="phase-agents"] .agent-chip {
        display: grid;
        grid-template-columns: auto minmax(0, 1fr);
        gap: 8px;
        align-items: center;
        padding: 8px 10px;
      }

      .agent-main {
        display: flex;
        align-items: baseline;
        justify-content: space-between;
        gap: 10px;
        min-width: 0;
      }

      .agent-name {
        min-width: 0;
        overflow: hidden;
        text-overflow: ellipsis;
        white-space: nowrap;
        font-weight: 720;
      }

      .agent-status-dot {
        flex: 0 0 auto;
        width: 8px;
        height: 8px;
        border-radius: 999px;
        background: #98a2b3;
      }

      .agent-chip[data-status="running"] .agent-status-dot,
      .agent-summary-chip[data-status="running"] .agent-status-dot {
        background: #f59e0b;
      }

      .agent-chip[data-status="completed"] .agent-status-dot,
      .agent-summary-chip[data-status="completed"] .agent-status-dot {
        background: #16a34a;
      }

      .agent-chip[data-status="failed"] .agent-status-dot,
      .agent-summary-chip[data-status="failed"] .agent-status-dot {
        background: #dc2626;
      }

      .agent-meta {
        flex: 0 0 auto;
        color: #667085;
        font-size: 12px;
        font-weight: 520;
      }

      .agent-row-body {
        display: grid;
        gap: 3px;
        min-width: 0;
      }

      .agent-activity {
        display: grid;
        gap: 3px;
        margin-top: 6px;
        color: #475467;
        font-size: 12px;
        line-height: 1.35;
      }

      .agent-activity-line {
        display: block;
        overflow: hidden;
        text-overflow: ellipsis;
        white-space: nowrap;
      }

      .agent-summary-list {
        display: flex;
        flex-wrap: wrap;
        gap: 5px;
      }

      .agent-summary {
        min-width: 0;
      }

      .agent-summary-chip {
        display: inline-flex;
        width: auto;
        max-width: 100%;
        min-height: 28px;
        align-items: center;
        gap: 6px;
        padding: 4px 8px;
        border-color: #d8dee8;
        background: #ffffff;
        color: #475467;
        font-size: 12px;
      }

      .agent-summary-name {
        min-width: 0;
        overflow: hidden;
        text-overflow: ellipsis;
        white-space: nowrap;
      }

      .agent-summary-chip[data-status="running"] {
        border-color: #f59e0b;
        background: #fffbeb;
        color: #92400e;
      }

      .agent-summary-chip[data-status="completed"] {
        border-color: #bbf7d0;
        background: #f0fdf4;
        color: #166534;
      }

      .agent-summary-chip[data-status="failed"] {
        border-color: #fecaca;
        background: #fef2f2;
        color: #991b1b;
      }

      [data-testid="agent-detail"] > section {
        margin-top: 14px;
        padding-left: 12px;
        border-left: 3px solid #d8dee8;
      }

      [data-testid="agent-detail"] > details {
        margin-top: 12px;
        padding-left: 12px;
        border-left: 3px solid #d8dee8;
      }

      [data-testid="agent-detail"] summary {
        display: inline-block;
        cursor: pointer;
        color: #344054;
        font-size: 13px;
        font-weight: 720;
        transform-origin: left center;
        transition: transform 140ms cubic-bezier(0.23, 1, 0.32, 1),
          filter 140ms cubic-bezier(0.23, 1, 0.32, 1);
      }

      [data-testid="agent-detail"] summary:active {
        transform: scale(0.985);
        filter: brightness(0.98);
      }

      .detail-state {
        display: grid;
        gap: 8px;
        margin-bottom: 12px;
      }

      .detail-state p,
      .detail-panel p {
        margin-bottom: 6px;
      }

      .detail-state strong {
        display: block;
        margin-right: 0;
        color: #1f2937;
        font-size: 16px;
      }

      .detail-panel {
        margin-top: 12px;
        padding-left: 12px;
        border-left: 3px solid #d8dee8;
      }

      .detail-kicker {
        margin-bottom: 4px;
        color: #667085;
        font-size: 13px;
      }

      .detail-meta {
        margin-bottom: 18px;
        color: #475467;
        font-size: 13px;
        font-weight: 620;
      }

      .preview-more {
        color: #667085;
      }

      .detail-text {
        margin: 0 0 12px;
        font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
        font-size: 12px;
        line-height: 1.45;
        white-space: pre-wrap;
        overflow-wrap: anywhere;
      }

      .activity-list {
        display: grid;
        gap: 7px;
        margin-bottom: 16px;
      }

      .activity-row {
        line-height: 1.35;
      }

      [data-testid="agent-detail"] ol,
      [data-testid="logs"] ul,
      [data-testid="recent-events"] ul {
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

      [data-testid="result"],
      [data-testid="failure"] {
        margin-top: 16px;
      }

      .events-panel {
        display: grid;
        gap: 10px;
        margin-top: 16px;
        color: #475467;
        font-size: 13px;
      }

      [data-testid="recent-events"] {
        min-width: 0;
        border-top: 1px solid #d8dee8;
        padding-top: 12px;
      }

      [data-testid="recent-events"] h2 {
        margin-bottom: 8px;
        color: #344054;
        font-size: 13px;
      }

      [data-testid="recent-events"] ul,
      [data-testid="logs"] ul {
        padding-left: 20px;
      }

      [data-testid="recent-events"] li,
      [data-testid="logs"] li {
        margin-bottom: 4px;
        overflow-wrap: anywhere;
      }

      [data-testid="logs"] {
        min-width: 0;
      }

      [data-testid="logs"] summary {
        display: inline-block;
        cursor: pointer;
        color: #344054;
        font-size: 13px;
        font-weight: 720;
        transform-origin: left center;
        transition: transform 140ms cubic-bezier(0.23, 1, 0.32, 1),
          filter 140ms cubic-bezier(0.23, 1, 0.32, 1);
      }

      [data-testid="logs"] summary:active {
        transform: scale(0.985);
        filter: brightness(0.98);
      }

      [data-testid="failure"] {
        border-color: #fecaca;
        background: #fff7f7;
        color: #991b1b;
      }

      @media (hover: hover) and (pointer: fine) {
        button:hover {
          border-color: #8fa3bd;
          background: #f8fafc;
        }

        .phase-chip:hover {
          background: transparent;
        }

        [data-testid="agent-detail"] summary:hover,
        [data-testid="logs"] summary:hover {
          color: #1f2937;
        }
      }

      @media (prefers-reduced-motion: reduce) {
        button,
        [data-testid="agent-detail"] summary,
        [data-testid="logs"] summary {
          transition-duration: 0ms;
        }

        button:active,
        [data-testid="agent-detail"] summary:active,
        [data-testid="logs"] summary:active {
          transform: none;
          filter: brightness(0.98);
        }
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
          margin-bottom: 14px;
        }

        .status-strip {
          grid-template-columns: 1fr;
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

        [data-testid="phase-timeline"],
        [data-testid="phase-list"],
        [data-testid="agent-detail"],
        [data-testid="result"],
        [data-testid="failure"] {
          width: 100%;
        }
      }
    </style>
    <main id="run" data-run-id={@run_id}>
      <header data-testid="run-header">
        <h1>{@run_projection.tree_name || "Run"}</h1>
        <section data-testid="status-strip" class="status-strip" aria-label="Run status">
          <div data-testid="run-state" class="status-item">
            <span>State</span>
            <strong class="status-value" data-status={@run_projection.state}>
              <span class="status-dot" aria-hidden="true"></span>
              <span>{@run_projection.state}</span>
            </strong>
          </div>
          <div data-testid="run-phase" class="status-item">
            <span>Current phase</span>
            <strong>{phase_label(@run_projection.phase)}</strong>
          </div>
          <span
            class="lifecycle-button"
            data-testid="lifecycle-action"
            data-action={@run_projection.lifecycle_action.action}
            data-enabled={@run_projection.lifecycle_action.enabled}
            data-method={@run_projection.lifecycle_action.method}
            data-href={@run_projection.lifecycle_action.href}
            aria-disabled={if @run_projection.lifecycle_action.enabled, do: nil, else: "true"}
          >
            <span class="status-kicker">Lifecycle</span>
            <strong>{@run_projection.lifecycle_action.label}</strong>
            <small :if={!@run_projection.lifecycle_action.enabled}>
              {@run_projection.lifecycle_action.reason}
            </small>
          </span>
          <div data-testid="run-counters" class="status-item">
            <span>Counters</span>
            <div class="run-counters">
              <span>{plural_count(@run_projection.agent_count, "agent")}</span>
              <span>{plural_count(@run_projection.event_count, "event")}</span>
              <span>{format_tokens(total_tokens(@run_projection.usage))}</span>
            </div>
          </div>
          <div class="status-item">
            <label for={"run-id-" <> @run_id}>Run id</label>
            <input
              id={"run-id-" <> @run_id}
              data-testid="run-id"
              class="run-id-input"
              type="text"
              value={@run_id}
              readonly
              onclick="this.select()"
              aria-label="Run id"
            />
          </div>
        </section>
      </header>

      <section data-testid="inspector">
        <nav data-testid="phase-timeline" aria-label="Workflow timeline">
          <h2>Workflow queue</h2>
          <div data-testid="phase-list">
            <section
              :for={phase <- @status.phases}
              data-testid="phase-row"
              data-phase-id={phase.id}
              data-status={phase_status(@status, phase)}
              data-expanded={to_string(phase.id == @focused_phase_id)}
              class="phase-row"
            >
              <button
                type="button"
                phx-click="focus_phase"
                phx-value-id={phase.id}
                data-testid="phase-item"
                class="phase-chip"
                data-status={phase_status(@status, phase)}
                aria-pressed={phase.id == @focused_phase_id}
                aria-expanded={to_string(phase.id == @focused_phase_id)}
                aria-controls={"phase-agents-" <> phase.id}
              >
                <span class="phase-main">
                  <span class="phase-name">{phase.name}</span>
                  <span class="phase-meta">{phase_status_label(@status, phase)}</span>
                </span>
                <span class="phase-count">{completed_count(phase)}/{length(phase.agents)}</span>
              </button>
              <div
                id={"phase-agents-" <> phase.id}
                data-testid="phase-agents"
                aria-label={"Agents in #{phase.name}"}
              >
                <div
                  :for={agent <- phase.agents}
                  :if={phase.id == @focused_phase_id}
                  data-address={inspect(agent.address)}
                  data-iteration={agent.iteration}
                  data-testid={"phase-agent-#{agent_slug(agent)}"}
                  class="agent-row"
                  data-status={agent_status(agent)}
                  data-selected={to_string(agent_id(agent) == @selected_agent_id)}
                >
                  <button
                    type="button"
                    phx-click="select_agent"
                    phx-value-id={agent_id(agent)}
                    phx-value-phase-id={phase.id}
                    class="agent-chip"
                    data-status={agent_status(agent)}
                    aria-pressed={agent_id(agent) == @selected_agent_id}
                  >
                    <span class="agent-status-dot" aria-hidden="true"></span>
                    <span class="agent-row-body">
                      <span class="sr-only">Status: {status_label(agent)}</span>
                      <span class="agent-main">
                        <span class="agent-name">{agent_title(agent)}</span>
                        <span class="agent-meta">{agent_marker(@status, agent)}</span>
                      </span>
                      <span
                        data-testid="agent-activity"
                        class="agent-activity-line"
                        title={full_activity_summary(agent)}
                      >
                        {timeline_activity(agent)}
                      </span>
                    </span>
                  </button>
                </div>
                <div :if={phase.id != @focused_phase_id and phase.agents != []} class="agent-summary-list">
                  <div
                    :for={agent <- phase.agents}
                    data-testid={"phase-agent-#{agent_slug(agent)}"}
                    class="agent-summary"
                    data-status={agent_status(agent)}
                    data-selected={to_string(agent_id(agent) == @selected_agent_id)}
                  >
                    <button
                      type="button"
                      phx-click="select_agent"
                      phx-value-id={agent_id(agent)}
                      phx-value-phase-id={phase.id}
                      class="agent-summary-chip"
                      data-status={agent_status(agent)}
                      aria-pressed={agent_id(agent) == @selected_agent_id}
                    >
                      <span class="agent-status-dot" aria-hidden="true"></span>
                      <span class="sr-only">Status: {status_label(agent)}</span>
                      <span class="agent-summary-name">{agent_title(agent)}</span>
                      <span class="agent-marker">{agent_marker(@status, agent)}</span>
                    </button>
                  </div>
                </div>
                <p :if={phase.agents == []}>No agents yet</p>
              </div>
            </section>
          </div>
          <p :if={@status.phases == []}>No phases yet</p>
        </nav>

        <section data-testid="agent-detail">
          <% agent = selected_agent(@status, @focused_phase_id, @selected_agent_id) %>
          <% active_agent = active_agent(@status) %>
          <% rejections = detail_rejections(@status, @focused_phase_id, @selected_agent_id) %>
          <% failed_rejections = failed_rejections(@status, rejections) %>
          <%= if agent do %>
            <h2>Execution state</h2>
            <div data-testid="agent-execution-state" class="detail-state">
              <p>
                <span class="detail-kicker">State</span>
                <strong>{status_label(agent)}</strong>
                <span class="detail-meta">{agent_meta(agent)}</span>
              </p>
              <p>
                <span class="detail-kicker">Selected agent</span>
                <strong>{agent_title(agent)}</strong>
                <span class="detail-meta">
                  iteration {agent.iteration} · address {inspect(agent.address)}
                </span>
              </p>
              <p
                :if={active_agent && agent_id(active_agent) != agent_id(agent)}
                data-testid="active-agent"
              >
                <span class="detail-kicker">Active now</span>
                <strong>{agent_title(active_agent)}</strong>
                <span class="detail-meta">
                  {status_label(active_agent)} · iteration {active_agent.iteration} · address {inspect(active_agent.address)}
                </span>
              </p>
            </div>

            <section data-testid="latest-event" class="detail-panel">
              <h3>Latest event</h3>
              <p class="detail-text">
                {latest_meaningful_event(@status, agent, rejections, failed_rejections)}
              </p>
            </section>

            <section data-testid="retry-context" class="detail-panel">
              <h3>Retry context</h3>
              <p>{retry_context_text(rejections, failed_rejections)}</p>
            </section>

            <section data-testid="final-outcome" class="detail-panel">
              <h3>Final outcome</h3>
              <p class="detail-text">{final_outcome_text(agent)}</p>
            </section>

            <details data-testid="prompt-preview">
              <summary>Prompt preview · {line_count(agent.prompt)} lines</summary>
              <p class="detail-text">{prompt_preview(agent.prompt)}</p>
              <p class="preview-more" :if={hidden_line_count(agent.prompt, 2) > 0}>
                ... {hidden_line_count(agent.prompt, 2)} more lines
              </p>
            </details>

            <details :if={agent_has_result?(agent)} data-testid="raw-output">
              <summary>Raw output</summary>
              <p class="detail-text">{outcome_preview(agent)}</p>
            </details>

            <details data-testid="raw-activity">
              <summary>Raw activity · last {length(recent_activity(agent))} of {length(agent.activity)}</summary>
              <div class="activity-list">
                <div :for={entry <- recent_activity(agent)} class="activity-row">
                  {activity_line(entry)}
                </div>
              </div>
              <p :if={agent.activity == []}>No activity recorded</p>
            </details>
          <% else %>
            <p :if={rejections == []}>No agent selected</p>
          <% end %>
          <details :if={rejections != []} data-testid="retry-history">
            <summary>Retry history</summary>
            <h3>Rejected attempts</h3>
            <ol>
              <li :for={rejection <- rejections}>
                <strong>attempt {rejection.attempt}</strong>
                <span> {inspect(rejection.reason)}</span>
                <pre>{inspect(rejection.output)}</pre>
                <ol :if={rejection.activity != []}>
                  <li :for={entry <- rejection.activity}>
                    <strong>{activity_label(entry)}</strong>
                    <span :if={activity_status(entry)}> {activity_status(entry)}</span>
                    <span :if={activity_summary(entry)}> {activity_summary(entry)}</span>
                  </li>
                </ol>
                <p :if={rejection.activity == []}>No activity recorded</p>
              </li>
            </ol>
          </details>
          <details :if={failed_rejections != []} data-testid="failed-attempts">
            <summary>Failed attempts</summary>
            <h3>Failed attempts</h3>
            <ol>
              <li :for={rejection <- failed_rejections}>
                <strong>iteration {rejection.iteration}, attempt {rejection.attempt}</strong>
                <span> {inspect(rejection.reason)}</span>
                <pre>{inspect(rejection.output)}</pre>
                <ol :if={rejection.activity != []}>
                  <li :for={entry <- rejection.activity}>
                    <strong>{activity_label(entry)}</strong>
                    <span :if={activity_status(entry)}> {activity_status(entry)}</span>
                    <span :if={activity_summary(entry)}> {activity_summary(entry)}</span>
                  </li>
                </ol>
                <p :if={rejection.activity == []}>No activity recorded</p>
              </li>
            </ol>
          </details>
        </section>
      </section>

      <section class="events-panel" aria-label="Run events">
        <section :if={@status.logs != []} data-testid="recent-events">
          <h2>Recent events</h2>
          <ul>
            <li :for={line <- recent_logs(@status.logs)}>{line}</li>
          </ul>
        </section>

        <details data-testid="logs">
          <summary>View logs · {plural_count(length(@status.logs), "entry")}</summary>
          <ul :if={@status.logs != []}>
            <li :for={line <- @status.logs}>{line}</li>
          </ul>
          <p :if={@status.logs == []}>No log entries</p>
        </details>
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

  defp first_phase_id(%Status{phases: [%{id: id} | _]}), do: id
  defp first_phase_id(%Status{}), do: nil

  defp valid_phase_id(%Status{} = status, phase_id) when is_binary(phase_id) do
    if Enum.any?(status.phases, &(&1.id == phase_id)), do: phase_id
  end

  defp valid_phase_id(%Status{}, _phase_id), do: nil

  defp first_agent_id(%Status{} = status, phase_id) do
    case focused_phase(status, phase_id) do
      %{agents: [agent | _]} -> agent_id(agent)
      _phase -> nil
    end
  end

  defp valid_agent_id(%Status{} = status, phase_id, agent_id) when is_binary(agent_id) do
    status
    |> focused_phase(phase_id)
    |> case do
      %{agents: agents} ->
        if Enum.any?(agents, &(agent_id(&1) == agent_id)), do: agent_id

      _phase ->
        nil
    end
  end

  defp valid_agent_id(%Status{}, _phase_id, _agent_id), do: nil

  defp focused_phase(%Status{} = status, phase_id),
    do: Enum.find(status.phases, &(&1.id == phase_id))

  defp phase_status(%Status{state: :failed, failure: %{address: address}}, phase) do
    if Enum.any?(phase.agents, &List.starts_with?(address, &1.address)) do
      "failed"
    else
      completed_or_pending_phase(phase)
    end
  end

  defp phase_status(%Status{state: :completed}, phase), do: completed_or_pending_phase(phase)

  defp phase_status(%Status{current_phase_id: current_phase_id}, %{id: current_phase_id} = phase) do
    if Enum.any?(phase.agents, &(Map.get(&1, :status) in [:running, "running"])) do
      "running"
    else
      completed_or_pending_phase(phase)
    end
  end

  defp phase_status(_status, phase), do: completed_or_pending_phase(phase)

  defp phase_status_label(status, phase) do
    status
    |> phase_status(phase)
    |> String.capitalize()
  end

  defp completed_count(phase) do
    Enum.count(phase.agents, &(Map.get(&1, :status) in [:completed, "completed"]))
  end

  defp completed_or_pending_phase(%{agents: []}), do: "pending"

  defp completed_or_pending_phase(%{agents: agents}) do
    if Enum.all?(agents, &(Map.get(&1, :status) in [:completed, "completed"])) do
      "completed"
    else
      "running"
    end
  end

  defp selected_agent(%Status{} = status, phase_id, agent_id) do
    status
    |> focused_phase(phase_id)
    |> case do
      %{agents: agents} -> Enum.find(agents, &(agent_id(&1) == agent_id))
      _phase -> nil
    end
  end

  defp active_agent(%Status{} = status) do
    status.phases
    |> Enum.flat_map(&Map.get(&1, :agents, []))
    |> Enum.find(&(agent_status(&1) == "running"))
  end

  defp detail_rejections(%Status{} = status, phase_id, agent_id) do
    case selected_agent(status, phase_id, agent_id) do
      %{address: address, iteration: iteration} ->
        Enum.filter(status.rejected, &(&1.address == address and &1.iteration == iteration))

      nil ->
        Enum.filter(status.rejected, &(&1.phase_id == phase_id))
    end
  end

  defp failed_rejections(%Status{failure: nil}, _visible_rejections), do: []

  defp failed_rejections(
         %Status{failure: %{address: address, iteration: iteration}} = status,
         visible_rejections
       ) do
    visible = MapSet.new(Enum.map(visible_rejections, &rejection_id/1))

    status.rejected
    |> Enum.filter(&(&1.address == address and &1.iteration == iteration))
    |> Enum.reject(&(rejection_id(&1) in visible))
  end

  defp rejection_id(rejection), do: {rejection.address, rejection.iteration, rejection.attempt}

  defp latest_meaningful_event(%Status{} = status, agent, rejections, failed_rejections) do
    cond do
      agent_failed?(status, agent) ->
        "Failed: " <> inspect(status.failure.reason)

      activity = last_activity(agent) ->
        activity_line(activity)

      agent_has_result?(agent) ->
        "Completed with final outcome"

      agent_status(agent) == "running" ->
        "Running; waiting for provider activity"

      rejection = List.last(rejections) ->
        rejection_event_line(rejection)

      rejection = List.last(failed_rejections) ->
        rejection_event_line(rejection)

      true ->
        "No activity recorded"
    end
  end

  defp agent_failed?(%Status{failure: %{address: address, iteration: iteration}}, %{
         address: address,
         iteration: iteration
       }),
       do: true

  defp agent_failed?(%Status{}, _agent), do: false

  defp last_activity(agent) do
    agent
    |> Map.get(:activity, [])
    |> List.last()
  end

  defp rejection_event_line(rejection) do
    case List.last(Map.get(rejection, :activity, [])) do
      nil -> "Rejected attempt #{rejection.attempt}: " <> inspect(rejection.reason)
      activity -> activity_line(activity)
    end
  end

  defp retry_context_text(rejections, failed_rejections) do
    parts =
      [
        attempt_count_text(length(rejections), "rejected"),
        attempt_count_text(length(failed_rejections), "failed")
      ]
      |> Enum.reject(&blank?/1)

    case parts do
      [] -> "No retry activity"
      parts -> Enum.join(parts, " · ")
    end
  end

  defp attempt_count_text(0, _kind), do: nil
  defp attempt_count_text(count, kind), do: plural_count(count, "#{kind} attempt")

  defp final_outcome_text(agent) do
    cond do
      agent_has_result?(agent) ->
        outcome_preview(agent)

      agent_status(agent) == "failed" ->
        "No final outcome"

      true ->
        "Pending final outcome"
    end
  end

  defp agent_has_result?(agent),
    do: Map.has_key?(agent, :result) and not is_nil(Map.get(agent, :result))

  defp agent_id(agent),
    do:
      "agent-" <> Enum.map_join(agent.address, "-", &to_string/1) <> "-i#{agent_iteration(agent)}"

  defp agent_slug(agent) do
    slug =
      agent_title(agent)
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")

    case slug do
      "" -> agent_id(agent)
      slug -> "#{slug}-i#{agent_iteration(agent)}"
    end
  end

  defp agent_iteration(agent), do: Map.get(agent, :iteration, 0)

  defp phase_label(nil), do: "No phase"
  defp phase_label(""), do: "No phase"
  defp phase_label(phase), do: phase

  defp plural_count(1, word), do: "1 #{word}"
  defp plural_count(count, word), do: "#{count} #{plural_word(word)}"

  defp plural_word(word) do
    if Regex.match?(~r/[^aeiou]y$/i, word) do
      String.replace_suffix(word, "y", "ies")
    else
      word <> "s"
    end
  end

  defp csrf_token, do: Plug.CSRFProtection.get_csrf_token()

  defp agent_title(%{label: label}) when is_binary(label) and label != "", do: label

  defp agent_title(%{prompt: prompt}),
    do: prompt |> String.split(~r/\s+/, trim: true) |> Enum.take(4) |> Enum.join(" ")

  defp agent_status(%{status: status}) when status in [:completed, "completed"], do: "completed"
  defp agent_status(%{status: status}) when status in [:running, "running"], do: "running"
  defp agent_status(%{status: status}) when status in [:failed, "failed"], do: "failed"
  defp agent_status(_agent), do: "pending"

  defp status_label(%{status: :completed}), do: "Completed"
  defp status_label(%{status: "completed"}), do: "Completed"
  defp status_label(%{status: :running}), do: "Running"
  defp status_label(%{status: "running"}), do: "Running"
  defp status_label(%{status: :failed}), do: "Failed"
  defp status_label(%{status: "failed"}), do: "Failed"
  defp status_label(_agent), do: "Pending"

  defp agent_marker(%Status{} = status, agent) do
    case rejection_count(status, agent) do
      count when count > 0 ->
        plural_count(count, "retry")

      _count ->
        agent_outcome_marker(agent)
    end
  end

  defp rejection_count(%Status{rejected: rejected}, %{address: address, iteration: iteration}) do
    Enum.count(rejected, &(&1.address == address and &1.iteration == iteration))
  end

  defp agent_outcome_marker(%{status: status}) when status in [:completed, "completed"],
    do: "outcome"

  defp agent_outcome_marker(%{status: status}) when status in [:failed, "failed"], do: "failed"
  defp agent_outcome_marker(%{status: status}) when status in [:running, "running"], do: "active"
  defp agent_outcome_marker(_agent), do: "pending"

  defp agent_meta(agent) do
    [
      "Codex",
      format_tokens(total_tokens(Map.get(agent, :usage))),
      plural_count(tool_count(agent), "tool")
    ]
    |> Enum.join(" · ")
  end

  defp recent_activity(agent), do: agent |> Map.get(:activity, []) |> Enum.take(-4)

  defp recent_logs(logs), do: Enum.take(logs, -3)

  defp timeline_activity(agent), do: agent |> full_activity_summary() |> line_preview(1, 120)

  defp full_activity_summary(agent) do
    agent
    |> Map.get(:activity, [])
    |> List.last()
    |> case do
      nil -> "No activity recorded"
      entry -> activity_line(entry)
    end
  end

  defp activity_line(entry) do
    case formatted_tool_call(entry) do
      nil -> generic_activity_line(entry)
      formatted -> formatted
    end
  end

  defp generic_activity_line(entry) do
    [activity_label(entry), activity_status(entry), activity_summary(entry)]
    |> Enum.reject(&blank?/1)
    |> Enum.join(" · ")
  end

  defp activity_label(entry), do: Map.get(entry, :label) || Map.get(entry, "label") || "Activity"
  defp activity_status(entry), do: Map.get(entry, :status) || Map.get(entry, "status")
  defp activity_summary(entry), do: Map.get(entry, :summary) || Map.get(entry, "summary")

  defp formatted_tool_call(entry) do
    label = activity_label(entry)
    summary = activity_summary(entry) || ""

    cond do
      String.downcase(label) in ["bash", "shell"] ->
        "Bash(" <> truncate_arg(summary) <> ")"

      String.downcase(label) == "command execution" ->
        "Bash(" <> truncate_arg(shell_command_arg(summary)) <> ")"

      true ->
        nil
    end
  end

  defp shell_command_arg(summary) do
    case Regex.run(~r/(?:\/bin\/)?(?:zsh|bash|sh)\s+-lc\s+(.+)$/, summary) do
      [_, arg] -> unquote_shell(arg)
      _match -> summary
    end
  end

  defp unquote_shell("'" <> rest) do
    rest
    |> String.trim_trailing("'")
    |> String.replace("'\"'\"'", "'")
  end

  defp unquote_shell("\"" <> rest), do: String.trim_trailing(rest, "\"")
  defp unquote_shell(text), do: text

  defp truncate_arg(text) do
    text = String.replace(to_string(text), ~r/\s+/, " ")

    if String.length(text) <= 72 do
      text
    else
      String.slice(text, 0, 72) <> "..."
    end
  end

  defp prompt_preview(prompt), do: line_preview(prompt, 2, 220)

  defp outcome_preview(%{result: result}),
    do: result |> inspect(limit: 12, printable_limit: 900) |> line_preview(8, 260)

  defp outcome_preview(_agent), do: "pending"

  defp line_preview(text, max_lines, max_line_length) do
    text
    |> to_string()
    |> String.split("\n")
    |> Enum.take(max_lines)
    |> Enum.map(&truncate_line(&1, max_line_length))
    |> Enum.join("\n")
  end

  defp line_count(text), do: text |> to_string() |> String.split("\n") |> length()

  defp hidden_line_count(text, visible) do
    max(line_count(text) - visible, 0)
  end

  defp truncate_line(line, max_length) do
    if String.length(line) <= max_length do
      line
    else
      String.slice(line, 0, max_length) <> "..."
    end
  end

  defp total_tokens(%{total_tokens: total}) when is_integer(total), do: total
  defp total_tokens(%{"total_tokens" => total}) when is_integer(total), do: total
  defp total_tokens(_usage), do: 0

  defp tool_count(agent) do
    agent
    |> Map.get(:activity, [])
    |> Enum.count(&tool_activity?/1)
  end

  defp tool_activity?(entry) do
    kind = Map.get(entry, :kind) || Map.get(entry, "kind")
    label = activity_label(entry)

    kind == "tool" or
      String.contains?(String.downcase(label), "command") or
      String.contains?(String.downcase(label), "tool")
  end

  defp format_tokens(total) when total >= 1000 do
    :erlang.float_to_binary(total / 1000, decimals: 1) <> "k tok"
  end

  defp format_tokens(total), do: "#{total} tok"

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_value), do: false
end
