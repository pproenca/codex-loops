defmodule Workflow.Provider.Codex.EventEffect.Value do
  @moduledoc false

  alias Workflow.Provider.Activity
  alias Workflow.Provider.Usage

  defstruct failure: nil, final_message: nil, usage: nil, activity: []

  @type failure :: {:backend, map()} | nil
  @type t :: %__MODULE__{
          failure: failure(),
          final_message: String.t() | nil,
          usage: Usage.t() | nil,
          activity: [Activity.t()]
        }
end

defprotocol Workflow.Provider.Codex.EventEffect do
  @moduledoc false

  @spec effect(t()) :: Workflow.Provider.Codex.EventEffect.Value.t()
  def effect(event)
end

defimpl Workflow.Provider.Codex.EventEffect, for: Workflow.Provider.Codex.Event.ThreadStarted do
  alias Workflow.Provider.Activity
  alias Workflow.Provider.Codex.EventEffect.Value

  def effect(event) do
    %Value{
      activity: [
        %Activity{
          kind: "lifecycle",
          label: "Thread started",
          summary: event.thread_id,
          status: :running
        }
      ]
    }
  end
end

defimpl Workflow.Provider.Codex.EventEffect, for: Workflow.Provider.Codex.Event.TurnStarted do
  alias Workflow.Provider.Activity
  alias Workflow.Provider.Codex.EventEffect.Value

  def effect(_event) do
    %Value{
      activity: [
        %Activity{kind: "lifecycle", label: "Turn started", summary: nil, status: :running}
      ]
    }
  end
end

defimpl Workflow.Provider.Codex.EventEffect, for: Workflow.Provider.Codex.Event.TurnCompleted do
  alias Workflow.Provider.Codex.EventEffect.Value

  def effect(event), do: %Value{usage: event.usage}
end

defimpl Workflow.Provider.Codex.EventEffect, for: Workflow.Provider.Codex.Event.TurnFailed do
  alias Workflow.Provider.Codex.EventEffect.Value

  def effect(event), do: %Value{failure: {:backend, event.detail}}
end

defimpl Workflow.Provider.Codex.EventEffect, for: Workflow.Provider.Codex.Event.StreamError do
  alias Workflow.Provider.Codex.EventEffect.Value

  def effect(event), do: %Value{failure: {:backend, event.detail}}
end

defimpl Workflow.Provider.Codex.EventEffect, for: Workflow.Provider.Codex.Event.Unknown do
  alias Workflow.Provider.Codex.EventEffect.Value

  def effect(_event), do: %Value{}
end

defimpl Workflow.Provider.Codex.EventEffect, for: Workflow.Provider.Codex.Event.AgentMessage do
  alias Workflow.Provider.Activity
  alias Workflow.Provider.Codex.EventEffect.Value

  def effect(%{text: ""} = item), do: %Value{final_message: item.final_message}

  def effect(%{state: :completed} = item) do
    %Value{
      final_message: item.final_message,
      activity: [assistant_activity(item.text, :completed)]
    }
  end

  def effect(item) do
    %Value{activity: [assistant_activity(item.text, :running)]}
  end

  defp assistant_activity(text, status) do
    %Activity{
      kind: "output",
      label: "Assistant",
      summary: truncate(text, 180),
      status: status
    }
  end

  defp truncate(text, limit) do
    if String.length(text) <= limit,
      do: :binary.copy(text),
      else: :binary.copy(String.slice(text, 0, limit)) <> "..."
  end
end

defimpl Workflow.Provider.Codex.EventEffect, for: Workflow.Provider.Codex.Event.Reasoning do
  alias Workflow.Provider.Activity
  alias Workflow.Provider.Codex.EventEffect.Value

  def effect(%{state: :completed} = item) do
    %Value{
      activity: [
        %Activity{kind: "reasoning", label: "Reasoning", summary: item.summary, status: :completed}
      ]
    }
  end

  def effect(_item), do: %Value{}
end

defimpl Workflow.Provider.Codex.EventEffect, for: Workflow.Provider.Codex.Event.ToolCall do
  alias Workflow.Provider.Activity
  alias Workflow.Provider.Codex.EventEffect.Value

  def effect(%{state: :completed} = item) do
    %Value{
      activity: [
        %Activity{kind: "tool", label: item.label, summary: item.summary, status: :completed}
      ]
    }
  end

  def effect(_item), do: %Value{}
end

defimpl Workflow.Provider.Codex.EventEffect, for: Workflow.Provider.Codex.Event.ActivityItem do
  alias Workflow.Provider.Activity
  alias Workflow.Provider.Codex.EventEffect.Value

  def effect(%{state: :completed} = item) do
    %Value{
      activity: [
        %Activity{kind: "event", label: item.label, summary: item.summary, status: :completed}
      ]
    }
  end

  def effect(_item), do: %Value{}
end

defimpl Workflow.Provider.Codex.EventEffect, for: Workflow.Provider.Codex.Event.UnknownItem do
  alias Workflow.Provider.Codex.EventEffect.Value

  def effect(_item), do: %Value{}
end
