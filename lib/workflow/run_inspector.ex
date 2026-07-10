defmodule Workflow.RunInspector do
  @moduledoc """
  Shared, pure projection for inspector-grade run details.

  The input is `Workflow.Status`, itself a fold of committed journal events. This
  module owns the UI/API-ready inspector rules that are not part of the generic
  status fold: stable agent identity, phase-local grouping, selected detail,
  normalized activity, rejected attempts, and rejected-only terminal failures.
  """

  alias Workflow.Status

  @enforce_keys [:run_id, :phases, :agents, :rejected_attempts, :failed_rejected_attempts]
  defstruct [
    :run_id,
    :phases,
    :agents,
    :rejected_attempts,
    :failed_rejected_attempts
  ]

  @type t :: %__MODULE__{
          run_id: String.t() | nil,
          phases: [map()],
          agents: [map()],
          rejected_attempts: [map()],
          failed_rejected_attempts: [map()]
        }

  @spec from_status(Status.t()) :: t()
  def from_status(%Status{} = status) do
    agents = Enum.map(status.agents, &agent/1)
    rejected_attempts = Enum.map(status.rejected, &rejected_attempt/1)

    %__MODULE__{
      run_id: status.run_id,
      phases: Enum.map(status.phases, &phase/1),
      agents: agents,
      rejected_attempts: rejected_attempts,
      failed_rejected_attempts:
        failed_rejected_attempts(status.failure, agents, rejected_attempts)
    }
  end

  @spec selection(t(), String.t() | nil, String.t() | nil) :: %{
          focused_phase_id: String.t() | nil,
          selected_agent_id: String.t() | nil
        }
  def selection(%__MODULE__{} = projection, phase_id \\ nil, agent_id \\ nil) do
    phase_id = valid_phase_id(projection, phase_id) || first_phase_id(projection)

    %{
      focused_phase_id: phase_id,
      selected_agent_id:
        valid_agent_id(projection, phase_id, agent_id) || first_agent_id(projection, phase_id)
    }
  end

  @spec detail(t(), String.t() | nil, String.t() | nil) :: %{
          phase: map() | nil,
          agents: [map()],
          agent: map() | nil,
          rejected_attempts: [map()],
          failed_rejected_attempts: [map()]
        }
  def detail(%__MODULE__{} = projection, phase_id, agent_id) do
    phase = focused_phase(projection, phase_id)
    agent = selected_agent(projection, phase_id, agent_id)
    rejected_attempts = detail_rejections(projection, phase_id, agent)

    %{
      phase: phase,
      agents: if(phase, do: phase.agents, else: []),
      agent: agent,
      rejected_attempts: rejected_attempts,
      failed_rejected_attempts: failed_rejections(projection, rejected_attempts)
    }
  end

  @spec focused_phase(t(), String.t() | nil) :: map() | nil
  def focused_phase(%__MODULE__{} = projection, phase_id) when is_binary(phase_id),
    do: Enum.find(projection.phases, &(&1.id == phase_id))

  def focused_phase(%__MODULE__{}, _phase_id), do: nil

  @spec selected_agent(t(), String.t() | nil, String.t() | nil) :: map() | nil
  def selected_agent(%__MODULE__{} = projection, phase_id, agent_id) when is_binary(agent_id) do
    projection
    |> focused_phase(phase_id)
    |> case do
      %{agents: agents} -> Enum.find(agents, &(&1.id == agent_id))
      _phase -> nil
    end
  end

  def selected_agent(%__MODULE__{}, _phase_id, _agent_id), do: nil

  @spec agent_id(map()) :: String.t()
  def agent_id(agent),
    do:
      "agent-" <>
        Enum.map_join(Map.fetch!(agent, :address), "-", &to_string/1) <>
        "-i#{agent_iteration(agent)}"

  @spec agent_slug(map()) :: String.t()
  def agent_slug(agent) do
    slug =
      agent
      |> Map.get(:prompt, "")
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")

    case slug do
      "" -> agent_id(agent)
      slug -> "#{slug}-i#{agent_iteration(agent)}"
    end
  end

  defp phase(phase) do
    %{
      id: phase.id,
      name: phase.name,
      address: phase.address,
      agents: Enum.map(phase.agents, &agent/1)
    }
  end

  defp agent(agent) do
    projected = %{
      address: agent.address,
      iteration: agent_iteration(agent),
      prompt: agent.prompt,
      outcome: agent.result,
      result: agent.result,
      usage: agent.usage,
      idempotency_key: agent.idempotency_key,
      activity: activity(agent.activity),
      phase_id: agent.phase_id,
      phase_name: agent.phase_name
    }

    projected
    |> Map.put(:id, agent_id(projected))
    |> Map.put(:slug, agent_slug(projected))
  end

  defp rejected_attempt(rejection) do
    %{
      id: rejection_id(rejection),
      address: rejection.address,
      iteration: agent_iteration(rejection),
      attempt: rejection.attempt,
      prompt: rejection.prompt,
      output: rejection.output,
      reason: rejection.reason,
      activity: activity(rejection.activity),
      phase_id: rejection.phase_id,
      phase_name: rejection.phase_name
    }
  end

  defp failed_rejected_attempts(nil, _agents, _rejected_attempts), do: []

  defp failed_rejected_attempts(
         %{address: address, iteration: iteration},
         agents,
         rejected_attempts
       ) do
    if Enum.any?(agents, &(&1.address == address and &1.iteration == iteration)) do
      []
    else
      Enum.filter(rejected_attempts, &(&1.address == address and &1.iteration == iteration))
    end
  end

  defp first_phase_id(%__MODULE__{phases: [%{id: id} | _]}), do: id
  defp first_phase_id(%__MODULE__{}), do: nil

  defp valid_phase_id(%__MODULE__{} = projection, phase_id) when is_binary(phase_id) do
    if Enum.any?(projection.phases, &(&1.id == phase_id)), do: phase_id
  end

  defp valid_phase_id(%__MODULE__{}, _phase_id), do: nil

  defp first_agent_id(%__MODULE__{} = projection, phase_id) do
    case focused_phase(projection, phase_id) do
      %{agents: [%{id: id} | _]} -> id
      _phase -> nil
    end
  end

  defp valid_agent_id(%__MODULE__{} = projection, phase_id, agent_id) when is_binary(agent_id) do
    projection
    |> focused_phase(phase_id)
    |> case do
      %{agents: agents} -> if Enum.any?(agents, &(&1.id == agent_id)), do: agent_id
      _phase -> nil
    end
  end

  defp valid_agent_id(%__MODULE__{}, _phase_id, _agent_id), do: nil

  defp detail_rejections(%__MODULE__{} = projection, _phase_id, %{
         address: address,
         iteration: iteration
       }) do
    Enum.filter(
      projection.rejected_attempts,
      &(&1.address == address and &1.iteration == iteration)
    )
  end

  defp detail_rejections(%__MODULE__{} = projection, phase_id, nil) do
    Enum.filter(projection.rejected_attempts, &(&1.phase_id == phase_id))
  end

  defp failed_rejections(%__MODULE__{} = projection, visible_rejections) do
    visible = MapSet.new(Enum.map(visible_rejections, &rejection_key/1))

    Enum.reject(
      projection.failed_rejected_attempts,
      &(rejection_key(&1) in visible)
    )
  end

  defp rejection_id(rejection) do
    {address, iteration, attempt} = rejection_key(rejection)
    "rejection-" <> Enum.map_join(address, "-", &to_string/1) <> "-i#{iteration}-a#{attempt}"
  end

  defp rejection_key(rejection),
    do:
      {Map.fetch!(rejection, :address), agent_iteration(rejection),
       Map.fetch!(rejection, :attempt)}

  defp agent_iteration(agent), do: Map.get(agent, :iteration, 0)

  defp activity(activity) when is_list(activity), do: Enum.map(activity, &activity_entry/1)
  defp activity(_activity), do: []

  defp activity_entry(entry) when is_map(entry) do
    %{
      kind: text(Map.get(entry, :kind) || Map.get(entry, "kind") || "activity"),
      label: text(Map.get(entry, :label) || Map.get(entry, "label") || "Activity"),
      status: optional_text(Map.get(entry, :status) || Map.get(entry, "status")),
      summary: optional_text(Map.get(entry, :summary) || Map.get(entry, "summary"))
    }
  end

  defp activity_entry(_entry) do
    %{kind: "activity", label: "Activity", status: nil, summary: nil}
  end

  defp optional_text(nil), do: nil
  defp optional_text(value), do: text(value)

  defp text(value) when is_binary(value), do: value
  defp text(value) when is_atom(value), do: Atom.to_string(value)
  defp text(value), do: inspect(value)
end
