defmodule Workflow.Provider.Codex.Event.ThreadStarted do
  @moduledoc false
  @enforce_keys [:thread_id]
  defstruct [:thread_id]

  @type t :: %__MODULE__{thread_id: String.t()}
end

defmodule Workflow.Provider.Codex.Event.TurnStarted do
  @moduledoc false
  defstruct []

  @type t :: %__MODULE__{}
end

defmodule Workflow.Provider.Codex.Event.TurnCompleted do
  @moduledoc false
  @enforce_keys [:usage]
  defstruct [:usage]

  @type t :: %__MODULE__{usage: Workflow.Provider.Usage.t()}
end

defmodule Workflow.Provider.Codex.Event.TurnFailed do
  @moduledoc false
  @enforce_keys [:detail]
  defstruct [:detail]

  @type t :: %__MODULE__{detail: map()}
end

defmodule Workflow.Provider.Codex.Event.StreamError do
  @moduledoc false
  @enforce_keys [:detail]
  defstruct [:detail]

  @type t :: %__MODULE__{detail: map()}
end

defmodule Workflow.Provider.Codex.Event.Unknown do
  @moduledoc false
  @enforce_keys [:type]
  defstruct [:type]

  @type t :: %__MODULE__{type: String.t() | nil}
end

defmodule Workflow.Provider.Codex.Event.AgentMessage do
  @moduledoc false
  @enforce_keys [:state, :text, :final_message]
  defstruct [:state, :text, :final_message]

  @type t :: %__MODULE__{
          state: Workflow.Provider.Codex.Event.state(),
          text: String.t(),
          final_message: String.t() | nil
        }
end

defmodule Workflow.Provider.Codex.Event.Reasoning do
  @moduledoc false
  @enforce_keys [:state, :summary]
  defstruct [:state, :summary]

  @type t :: %__MODULE__{state: Workflow.Provider.Codex.Event.state(), summary: String.t()}
end

defmodule Workflow.Provider.Codex.Event.ToolCall do
  @moduledoc false
  @enforce_keys [:state, :label, :summary]
  defstruct [:state, :label, :summary]

  @type t :: %__MODULE__{
          state: Workflow.Provider.Codex.Event.state(),
          label: String.t(),
          summary: String.t()
        }
end

defmodule Workflow.Provider.Codex.Event.ActivityItem do
  @moduledoc false
  @enforce_keys [:state, :label, :summary]
  defstruct [:state, :label, :summary]

  @type t :: %__MODULE__{
          state: Workflow.Provider.Codex.Event.state(),
          label: String.t(),
          summary: String.t()
        }
end

defmodule Workflow.Provider.Codex.Event.UnknownItem do
  @moduledoc false
  @enforce_keys [:type]
  defstruct [:type]

  @type t :: %__MODULE__{type: String.t() | nil}
end

defmodule Workflow.Provider.Codex.Event do
  @moduledoc """
  The single normalization boundary for Codex's extensible JSONL protocol.

  External string tags are consumed here and never escape as runtime dispatch
  data. Known variants become fixed internal structs. Unknown events and items
  remain explicit variants so a newer Codex CLI can add harmless stream data
  without breaking this provider.
  """

  alias Workflow.JSONValue
  alias Workflow.Provider.Codex.Event.ActivityItem
  alias Workflow.Provider.Codex.Event.AgentMessage
  alias Workflow.Provider.Codex.Event.Reasoning
  alias Workflow.Provider.Codex.Event.StreamError
  alias Workflow.Provider.Codex.Event.ThreadStarted
  alias Workflow.Provider.Codex.Event.ToolCall
  alias Workflow.Provider.Codex.Event.TurnCompleted
  alias Workflow.Provider.Codex.Event.TurnFailed
  alias Workflow.Provider.Codex.Event.TurnStarted
  alias Workflow.Provider.Codex.Event.Unknown
  alias Workflow.Provider.Codex.Event.UnknownItem
  alias Workflow.Provider.Usage

  @activity_item_types [
    "collab_agent_tool_call",
    "command_execution",
    "dynamic_tool_call",
    "error",
    "file_change",
    "image_generation",
    "mcp_tool_call",
    "todo_list",
    "tool_call",
    "web_search"
  ]

  @type t ::
          ThreadStarted.t()
          | TurnStarted.t()
          | TurnCompleted.t()
          | TurnFailed.t()
          | StreamError.t()
          | AgentMessage.t()
          | Reasoning.t()
          | ToolCall.t()
          | ActivityItem.t()
          | UnknownItem.t()
          | Unknown.t()
  @type state :: :started | :updated | :completed

  @spec normalize(map()) :: t()
  def normalize(%{"type" => "thread.started", "thread_id" => thread_id}) when is_binary(thread_id) do
    %ThreadStarted{thread_id: copy(thread_id)}
  end

  def normalize(%{"type" => "turn.started"}), do: %TurnStarted{}

  def normalize(%{"type" => "turn.completed", "usage" => usage}) when is_map(usage) do
    case usage(usage) do
      {:ok, usage} -> %TurnCompleted{usage: usage}
      :error -> %StreamError{detail: %{"message" => "codex emitted invalid turn usage"}}
    end
  end

  def normalize(%{"type" => "turn.completed"}) do
    %StreamError{detail: %{"message" => "codex completed a turn without usage"}}
  end

  def normalize(%{"type" => "turn.failed", "error" => %{"message" => message} = error}) when is_binary(message) do
    detail =
      case durable_value(error) do
        durable when is_map(durable) -> Map.put(durable, "message", copy(message))
        durable -> %{"message" => copy(message), "error" => durable}
      end

    %TurnFailed{detail: detail}
  end

  def normalize(%{"type" => "turn.failed", "error" => error}) do
    %TurnFailed{detail: %{"message" => "codex turn failed", "error" => durable_value(error)}}
  end

  def normalize(%{"type" => "turn.failed"}) do
    %TurnFailed{detail: %{"message" => "codex turn failed"}}
  end

  def normalize(%{"type" => "error", "message" => message}) when is_binary(message) do
    %StreamError{detail: %{"message" => copy(message)}}
  end

  def normalize(%{"type" => "error"} = event) do
    message = event |> Map.get("message", "codex stream failed") |> durable_value()
    %StreamError{detail: %{"message" => if(is_binary(message), do: message, else: inspect(message))}}
  end

  def normalize(%{"type" => "item.started", "item" => item}) when is_map(item) do
    normalize_item(item, :started)
  end

  def normalize(%{"type" => "item.updated", "item" => item}) when is_map(item) do
    normalize_item(item, :updated)
  end

  def normalize(%{"type" => "item.completed", "item" => item}) when is_map(item) do
    normalize_item(item, :completed)
  end

  def normalize(event) do
    type = event |> Map.get("type") |> known_type()
    %Unknown{type: type}
  end

  defp normalize_item(%{"type" => "agent_message"} = item, state) do
    {text, final_message} = agent_message(item, state)

    %AgentMessage{
      state: state,
      text: text,
      final_message: final_message
    }
  end

  defp normalize_item(%{"type" => "reasoning"} = item, state) do
    %Reasoning{state: state, summary: item |> item_summary() |> truncate(180)}
  end

  defp normalize_item(%{"type" => "tool_call"} = item, state) do
    %ToolCall{state: state, label: tool_label(item), summary: item |> item_summary() |> truncate(180)}
  end

  defp normalize_item(%{"type" => type} = item, state) when type in @activity_item_types do
    %ActivityItem{state: state, label: labelize(type), summary: item |> item_summary() |> truncate(180)}
  end

  defp normalize_item(item, _state) do
    %UnknownItem{type: item |> Map.get("type") |> known_type()}
  end

  defp usage(usage) do
    input = Map.get(usage, "input_tokens", 0)
    output = Map.get(usage, "output_tokens", 0)

    if is_integer(input) and input >= 0 and is_integer(output) and output >= 0 do
      {:ok, %Usage{input_tokens: input, output_tokens: output, total_tokens: input + output}}
    else
      :error
    end
  end

  defp message_text(text) when is_binary(text), do: text
  defp message_text([%{"text" => text} | _]) when is_binary(text), do: text
  defp message_text(_value), do: ""

  defp agent_message(%{"text" => text}, :completed) when is_binary(text) do
    text = copy(text)
    {text, text}
  end

  defp agent_message(item, _state) do
    {item |> Map.get("text") |> message_text() |> copy(), nil}
  end

  defp tool_label(item) do
    case Map.get(item, "name") || Map.get(item, "tool_name") do
      label when is_binary(label) -> copy(label)
      _other -> "Tool"
    end
  end

  defp item_summary(item) do
    item
    |> summary_value()
    |> to_summary()
  end

  defp summary_value(item) do
    Map.get(item, "text") ||
      Map.get(item, "summary") ||
      Map.get(item, "command") ||
      get_in(item, ["input", "cmd"]) ||
      Map.get(item, "input") ||
      Map.get(item, "arguments") ||
      Map.get(item, "output") ||
      Map.get(item, "type")
  end

  defp to_summary(value) when is_binary(value), do: value
  defp to_summary([%{"text" => text} | _]) when is_binary(text), do: text
  defp to_summary(value) when is_map(value), do: JSON.encode!(value)
  defp to_summary(value), do: inspect(value)

  defp truncate(text, limit) do
    if String.length(text) <= limit,
      do: copy(text),
      else: copy(String.slice(text, 0, limit)) <> "..."
  end

  defp labelize(type) do
    type
    |> String.replace("_", " ")
    |> String.capitalize()
    |> copy()
  end

  defp known_type(type) when is_binary(type), do: copy(type)
  defp known_type(_type), do: nil

  defp copy(value), do: :binary.copy(value)

  defp durable_value(value) do
    value = JSONValue.public(value)
    if JSONValue.durable_detail?(value), do: JSONValue.copy(value), else: inspect(value)
  end
end
