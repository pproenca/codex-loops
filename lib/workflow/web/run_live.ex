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
    phase_id = valid_phase_id(status, socket.assigns[:focused_phase_id]) || first_phase_id(status)

    agent_id =
      valid_agent_id(status, phase_id, socket.assigns[:selected_agent_id]) ||
        first_agent_id(status, phase_id)

    assign(socket,
      run_id: run_id,
      status: status,
      focused_phase_id: phase_id,
      selected_agent_id: agent_id
    )
  end

  defp focus_phase(socket, phase_id) do
    status = socket.assigns.status
    phase_id = valid_phase_id(status, phase_id) || first_phase_id(status)

    assign(socket,
      focused_phase_id: phase_id,
      selected_agent_id: first_agent_id(status, phase_id)
    )
  end

  defp select_agent(socket, agent_id) do
    status = socket.assigns.status
    phase_id = socket.assigns.focused_phase_id

    assign(socket,
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
          <dd data-testid="agent-count">{plural_count(length(@status.agents), "agent")}</dd>
          <dt>tokens</dt>
          <dd data-testid="usage">{@status.usage.total_tokens}</dd>
          <dt>events</dt>
          <dd data-testid="event-count">{@status.event_count}</dd>
        </dl>
      </header>

      <section data-testid="inspector">
        <nav data-testid="phase-list" aria-label="Phases">
          <button
            :for={phase <- @status.phases}
            type="button"
            phx-click="focus_phase"
            phx-value-id={phase.id}
            data-testid="phase-item"
            aria-pressed={phase.id == @focused_phase_id}
          >
            {phase.name} ({length(phase.agents)})
          </button>
          <p :if={@status.phases == []}>No phases yet</p>
        </nav>

        <section data-testid="agents">
          <% phase = focused_phase(@status, @focused_phase_id) %>
          <% agents = if phase, do: phase.agents, else: [] %>
          <h2>Agents ({length(agents)})</h2>
          <ol data-testid="phase-agents">
            <li
              :for={agent <- agents}
              data-address={inspect(agent.address)}
              data-iteration={agent.iteration}
              data-testid={"phase-agent-#{agent_slug(agent)}"}
            >
              <button
                type="button"
                phx-click="select_agent"
                phx-value-id={agent_id(agent)}
                aria-pressed={agent_id(agent) == @selected_agent_id}
              >
                {agent.prompt}
              </button>
            </li>
          </ol>
        </section>

        <section data-testid="agent-detail">
          <% agent = selected_agent(@status, @focused_phase_id, @selected_agent_id) %>
          <% rejections = detail_rejections(@status, @focused_phase_id, @selected_agent_id) %>
          <% failed_rejections = failed_rejections(@status, rejections) %>
          <%= if agent do %>
            <h2>Agent {inspect(agent.address)}</h2>
            <p>iteration {agent.iteration}</p>
            <h3>Prompt</h3>
            <pre>{agent.prompt}</pre>
            <h3>Activity</h3>
            <ol>
              <li :for={entry <- agent.activity}>
                <strong>{activity_label(entry)}</strong>
                <span :if={activity_status(entry)}> {activity_status(entry)}</span>
                <span :if={activity_summary(entry)}> {activity_summary(entry)}</span>
              </li>
            </ol>
            <p :if={agent.activity == []}>No activity recorded</p>
            <h3>Outcome</h3>
            <pre>{inspect(agent.result)}</pre>
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
                    <strong>{activity_label(entry)}</strong>
                    <span :if={activity_status(entry)}> {activity_status(entry)}</span>
                    <span :if={activity_summary(entry)}> {activity_summary(entry)}</span>
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
                    <strong>{activity_label(entry)}</strong>
                    <span :if={activity_status(entry)}> {activity_status(entry)}</span>
                    <span :if={activity_summary(entry)}> {activity_summary(entry)}</span>
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

  defp selected_agent(%Status{} = status, phase_id, agent_id) do
    status
    |> focused_phase(phase_id)
    |> case do
      %{agents: agents} -> Enum.find(agents, &(agent_id(&1) == agent_id))
      _phase -> nil
    end
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

  defp agent_id(agent),
    do:
      "agent-" <> Enum.map_join(agent.address, "-", &to_string/1) <> "-i#{agent_iteration(agent)}"

  defp agent_slug(agent) do
    slug =
      agent.prompt
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")

    case slug do
      "" -> agent_id(agent)
      slug -> "#{slug}-i#{agent_iteration(agent)}"
    end
  end

  defp agent_iteration(agent), do: Map.get(agent, :iteration, 0)

  defp plural_count(1, word), do: "1 #{word}"
  defp plural_count(count, word), do: "#{count} #{word}s"

  defp csrf_token, do: Plug.CSRFProtection.get_csrf_token()

  defp activity_label(entry), do: Map.get(entry, :label) || Map.get(entry, "label") || "Activity"
  defp activity_status(entry), do: Map.get(entry, :status) || Map.get(entry, "status")
  defp activity_summary(entry), do: Map.get(entry, :summary) || Map.get(entry, "summary")
end
