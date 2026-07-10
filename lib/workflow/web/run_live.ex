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

  alias Workflow.Event
  alias Workflow.Run.Stream, as: RunStream
  alias Workflow.Scheduler
  alias Workflow.Scheduler.RunProjection
  alias Workflow.Status

  @refresh_ms 1_000

  @impl true
  def mount(%{"run_id" => run_id}, _session, socket) do
    # Subscribe before the first fold so no commit slips through the gap between
    # folding and subscribing; the idempotent re-fold absorbs any overlap.
    if connected?(socket) do
      RunStream.subscribe(run_id)
      schedule_refresh()
    end

    {:ok, assign_projection(socket, run_id)}
  end

  @impl true
  def handle_info({:journal_committed, run_id, _event}, socket) do
    {:noreply, assign_projection(socket, run_id)}
  end

  def handle_info({:run_stream_event, run_id, %Event{} = event}, socket) do
    {:noreply, assign_stream_event(socket, run_id, event)}
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
    assign_projection(socket, run_id, status, run_projection)
  end

  defp assign_stream_event(socket, run_id, %Event{} = event) do
    status = Status.apply_progress(event, socket.assigns.status)

    run_projection = %{
      RunProjection.from_status(status)
      | lifecycle_action: socket.assigns.run_projection.lifecycle_action
    }

    assign_projection(socket, run_id, status, run_projection)
  end

  defp assign_projection(socket, run_id, %Status{} = status, %RunProjection{} = run_projection) do
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
      selected_agent_id: valid_agent_id(status, phase_id, agent_id) || first_agent_id(status, phase_id)
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
    <link rel="stylesheet" href="/assets/codex-loops/run.css?v=5" />
    <main id="run" data-run-id={@run_id}>
      <header data-testid="run-header">
        <p class="product-label">Codex Loops <span>Workflow run</span></p>
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

            <section data-testid="latest-activity" class="detail-panel">
              <h3>Latest activity</h3>
              <p class="detail-text">{latest_meaningful_event(@status, agent, rejections, failed_rejections)}</p>
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

      <section class="events-panel" aria-label="Run log entries">
        <section :if={@status.logs != []} data-testid="recent-events">
          <h2>Recent log entries</h2>
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

      <section :if={@status.state == :completed} data-testid="result">
        <span class="result-icon" aria-hidden="true">✓</span>
        <span>
          <span class="detail-kicker">Workflow result</span>
          <strong>{run_result_text(@status.result)}</strong>
        </span>
      </section>
      <section :if={@status.state == :failed} data-testid="failure">
        <span class="result-icon" aria-hidden="true">!</span>
        <span>
          <span class="detail-kicker">Workflow failed</span>
          <strong>
            Failed at {inspect(@status.failure.address)} · {inspect(@status.failure.reason)}
          </strong>
        </span>
      </section>
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

  defp focused_phase(%Status{} = status, phase_id), do: Enum.find(status.phases, &(&1.id == phase_id))

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

  defp failed_rejections(%Status{failure: %{address: address, iteration: iteration}} = status, visible_rejections) do
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
       }), do: true

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
      Enum.reject(
        [attempt_count_text(length(rejections), "rejected"), attempt_count_text(length(failed_rejections), "failed")],
        &blank?/1
      )

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

  defp agent_has_result?(agent), do: Map.has_key?(agent, :result) and not is_nil(Map.get(agent, :result))

  defp agent_id(agent), do: "agent-" <> Enum.map_join(agent.address, "-", &to_string/1) <> "-i#{agent_iteration(agent)}"

  defp agent_slug(agent) do
    slug =
      agent
      |> agent_title()
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

  defp agent_title(%{prompt: prompt}), do: prompt |> String.split(~r/\s+/, trim: true) |> Enum.take(4) |> Enum.join(" ")

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

  defp agent_outcome_marker(%{status: status}) when status in [:completed, "completed"], do: "outcome"

  defp agent_outcome_marker(%{status: status}) when status in [:failed, "failed"], do: "failed"
  defp agent_outcome_marker(%{status: status}) when status in [:running, "running"], do: "active"
  defp agent_outcome_marker(_agent), do: "pending"

  defp agent_meta(agent) do
    Enum.join(
      ["Codex", format_tokens(total_tokens(Map.get(agent, :usage))), plural_count(tool_count(agent), "tool")],
      " · "
    )
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

  defp outcome_preview(%{result: %{"echo" => echo}}) when is_binary(echo), do: line_preview(echo, 8, 260)
  defp outcome_preview(%{result: result}) when is_binary(result), do: line_preview(result, 8, 260)

  defp outcome_preview(%{result: result}) do
    result
    |> Jason.encode(pretty: true)
    |> case do
      {:ok, json} -> json
      {:error, _reason} -> inspect(result, limit: 12, printable_limit: 900)
    end
    |> line_preview(8, 260)
  end

  defp outcome_preview(_agent), do: "pending"

  defp run_result_text(:ok), do: "Completed successfully"
  defp run_result_text(result) when is_binary(result), do: result
  defp run_result_text(result), do: inspect(result)

  defp line_preview(text, max_lines, max_line_length) do
    text
    |> to_string()
    |> String.split("\n")
    |> Enum.take(max_lines)
    |> Enum.map_join("\n", &truncate_line(&1, max_line_length))
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
