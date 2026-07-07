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

  defp schedule_refresh, do: Process.send_after(self(), :refresh, @refresh_ms)

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

      .phase-chip[data-status="pending"] {
        border-color: #d8dee8;
        background: #f8fafc;
        color: #667085;
      }

      .phase-chip[data-status="running"] {
        border-color: #f59e0b;
        background: #fffbeb;
        color: #92400e;
      }

      .phase-chip[data-status="completed"] {
        border-color: #22c55e;
        background: #f0fdf4;
        color: #166534;
      }

      .phase-chip[data-status="failed"] {
        border-color: #ef4444;
        background: #fef2f2;
        color: #991b1b;
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

      [data-testid="phase-list"] button {
        padding: 9px 10px;
      }

      [data-testid="phase-agents"] {
        display: grid;
        gap: 8px;
        margin: 0;
        padding-left: 0;
      }

      [data-testid="phase-agents"] button {
        padding: 9px 10px;
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

      .agent-meta {
        flex: 0 0 auto;
        color: #667085;
        font-size: 12px;
        font-weight: 520;
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

      [data-testid="agent-detail"] > section {
        margin-top: 14px;
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
      </header>

      <section data-testid="inspector">
        <nav data-testid="phase-list" aria-label="Phases">
          <h2>Phases</h2>
          <button
            :for={phase <- @status.phases}
            type="button"
            phx-click="focus_phase"
            phx-value-id={phase.id}
            data-testid="phase-item"
            class="phase-chip"
            data-status={phase_status(@status, phase)}
            aria-pressed={phase.id == @focused_phase_id}
          >
            {phase.name} ({completed_count(phase)}/{length(phase.agents)})
          </button>
          <p :if={@status.phases == []}>No phases yet</p>
        </nav>

        <section data-testid="agents">
          <% phase = focused_phase(@status, @focused_phase_id) %>
          <% agents = if phase, do: phase.agents, else: [] %>
          <h2>Agents ({length(agents)})</h2>
          <div data-testid="phase-agents">
            <div
              :for={agent <- agents}
              data-address={inspect(agent.address)}
              data-iteration={agent.iteration}
              data-testid={"phase-agent-#{agent_slug(agent)}"}
            >
              <button
                type="button"
                phx-click="select_agent"
                phx-value-id={agent_id(agent)}
                class="agent-chip"
                data-status={agent_status(agent)}
                aria-pressed={agent_id(agent) == @selected_agent_id}
              >
                <span class="agent-main">
                  <span class="agent-name">
                    {agent_title(agent)}
                  </span>
                </span>
              </button>
            </div>
          </div>
        </section>

        <section data-testid="agent-detail">
          <% agent = selected_agent(@status, @focused_phase_id, @selected_agent_id) %>
          <% rejections = detail_rejections(@status, @focused_phase_id, @selected_agent_id) %>
          <% failed_rejections = failed_rejections(@status, rejections) %>
          <%= if agent do %>
            <h2>{agent_title(agent)}</h2>
            <p class="detail-kicker">{status_label(agent)} · {agent_meta(agent)}</p>
            <p class="detail-meta">iteration {agent.iteration} · address {inspect(agent.address)}</p>
            <h3>Prompt · {line_count(agent.prompt)} lines</h3>
            <p class="detail-text">{prompt_preview(agent.prompt)}</p>
            <p class="preview-more" :if={hidden_line_count(agent.prompt, 2) > 0}>
              ... {hidden_line_count(agent.prompt, 2)} more lines
            </p>
            <h3>Activity · last {length(recent_activity(agent))} of {length(agent.activity)}</h3>
            <div class="activity-list">
              <div :for={entry <- recent_activity(agent)} class="activity-row">
                {activity_line(entry)}
              </div>
            </div>
            <p :if={agent.activity == []}>No activity recorded</p>
            <h3>Outcome</h3>
            <p class="detail-text">{outcome_preview(agent)}</p>
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

  defp plural_count(1, word), do: "1 #{word}"
  defp plural_count(count, word), do: "#{count} #{word}s"

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
  defp status_label(_agent), do: "Running"

  defp agent_meta(agent) do
    [
      "Codex",
      format_tokens(total_tokens(Map.get(agent, :usage))),
      plural_count(tool_count(agent), "tool")
    ]
    |> Enum.join(" · ")
  end

  defp recent_activity(agent), do: agent |> Map.get(:activity, []) |> Enum.take(-4)

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
