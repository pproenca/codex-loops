defmodule Workflow.Provider.Codex.StreamAccumulator do
  @moduledoc false

  alias Workflow.Provider.Usage

  @type t :: %__MODULE__{
          schema: map() | nil,
          activity_sink: (map() -> term()) | nil,
          final_message: String.t() | nil,
          usage: Usage.t() | nil,
          activity: [map()],
          failure: {atom(), map()} | nil
        }

  defstruct schema: nil,
            activity_sink: nil,
            final_message: nil,
            usage: nil,
            activity: [],
            failure: nil

  @spec new(map() | nil, (map() -> term()) | nil) :: t()
  def new(schema, activity_sink), do: %__MODULE__{schema: schema, activity_sink: activity_sink}

  @spec observe_line(t(), String.t()) :: t()
  def observe_line(%__MODULE__{} = acc, line) when is_binary(line) do
    case JSON.decode(line) do
      {:ok, event} when is_map(event) ->
        observe_event(acc, event)

      {:ok, decoded} ->
        put_failure(acc, :backend, %{
          "message" => "codex emitted a non-object JSONL event",
          "event" => inspect(decoded)
        })

      {:error, reason} ->
        put_failure(acc, :backend, %{
          "message" => "codex emitted malformed JSONL",
          "line" => truncate(line, 180),
          "reason" => inspect(reason)
        })
    end
  end

  @spec finish(t()) ::
          {:ok, term(), Usage.t(), [map()]}
          | {:error, {:provider_failure, atom(), map(), Usage.t() | nil, [map()]}}
  def finish(%__MODULE__{failure: {kind, detail}} = acc) do
    {:error, {:provider_failure, kind, detail, acc.usage, acc.activity}}
  end

  def finish(%__MODULE__{final_message: nil} = acc) do
    {:error,
     {:provider_failure, :backend, %{"message" => "codex stream completed without a final assistant message"}, acc.usage,
      acc.activity}}
  end

  def finish(%__MODULE__{} = acc) do
    {:ok, shape(acc.final_message, acc.schema), acc.usage || %Usage{}, acc.activity}
  end

  defp observe_event(%__MODULE__{} = acc, event) do
    acc
    |> update_failure(event)
    |> update_final_message(event)
    |> update_usage(event)
    |> update_activity(event)
  end

  defp update_failure(acc, %{"type" => "turn.failed", "error" => %{"message" => message} = error}) do
    put_failure(acc, :backend, Map.put(error, "message", message))
  end

  defp update_failure(acc, %{"type" => "turn.failed", "error" => error}) do
    put_failure(acc, :backend, %{"message" => "codex turn failed", "error" => json_value(error)})
  end

  defp update_failure(acc, %{"type" => "error", "message" => message}) do
    put_failure(acc, :backend, %{"message" => message})
  end

  defp update_failure(acc, _event), do: acc

  defp put_failure(%__MODULE__{failure: nil} = acc, kind, detail), do: %{acc | failure: {kind, detail}}
  defp put_failure(%__MODULE__{} = acc, _kind, _detail), do: acc

  defp update_final_message(%__MODULE__{} = acc, %{
         "type" => "item.completed",
         "item" => %{"type" => "agent_message", "text" => text}
       })
       when is_binary(text) do
    %{acc | final_message: text}
  end

  defp update_final_message(%__MODULE__{} = acc, _event), do: acc

  defp update_usage(%__MODULE__{} = acc, %{"type" => "turn.completed", "usage" => usage}) when is_map(usage) do
    input = Map.get(usage, "input_tokens", 0)
    output = Map.get(usage, "output_tokens", 0)
    %{acc | usage: %Usage{input_tokens: input, output_tokens: output, total_tokens: input + output}}
  end

  defp update_usage(%__MODULE__{} = acc, _event), do: acc

  defp update_activity(%__MODULE__{} = acc, event) do
    entries = activity_entries(event)
    Enum.each(entries, &emit_activity(acc.activity_sink, &1))
    %{acc | activity: acc.activity ++ entries}
  end

  defp emit_activity(nil, _entry), do: :ok
  defp emit_activity(sink, entry) when is_function(sink, 1), do: sink.(entry)

  defp shape(text, nil), do: text

  defp shape(text, _schema) do
    case JSON.decode(text) do
      {:ok, value} -> value
      {:error, _reason} -> text
    end
  end

  defp activity_entries(%{"type" => "thread.started", "thread_id" => thread_id}) do
    [
      %{
        kind: "lifecycle",
        label: "Thread started",
        summary: thread_id,
        status: "running"
      }
    ]
  end

  defp activity_entries(%{"type" => "turn.started"}) do
    [%{kind: "lifecycle", label: "Turn started", summary: nil, status: "running"}]
  end

  defp activity_entries(%{"type" => event_type, "item" => %{"type" => "agent_message"} = item}) do
    case message_text(item) do
      "" ->
        []

      text ->
        [%{kind: "output", label: "Assistant", summary: truncate(text, 180), status: message_status(event_type)}]
    end
  end

  defp activity_entries(%{"type" => "item.completed", "item" => %{"type" => "reasoning"} = item}) do
    [%{kind: "reasoning", label: "Reasoning", summary: item_summary(item), status: "completed"}]
  end

  defp activity_entries(%{"type" => "item.completed", "item" => %{"type" => "tool_call"} = item}) do
    label = Map.get(item, "name") || Map.get(item, "tool_name") || "Tool"
    [%{kind: "tool", label: label, summary: item_summary(item), status: "completed"}]
  end

  defp activity_entries(%{"type" => "item.completed", "item" => %{"type" => type} = item}) do
    [%{kind: "event", label: labelize(type), summary: item_summary(item), status: "completed"}]
  end

  defp activity_entries(_event), do: []

  defp message_text(item), do: item |> Map.get("text") |> message_text_part()

  defp message_text_part(text) when is_binary(text), do: text
  defp message_text_part([%{"text" => text} | _]) when is_binary(text), do: text
  defp message_text_part(_value), do: ""

  defp message_status("item.completed"), do: "completed"
  defp message_status(_event_type), do: "running"

  defp item_summary(item) do
    item
    |> summary_value()
    |> to_summary()
    |> truncate(180)
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
    if String.length(text) <= limit, do: text, else: String.slice(text, 0, limit) <> "..."
  end

  defp labelize(type) when is_binary(type) do
    type
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp json_value(term) do
    case Jason.encode(term) do
      {:ok, _json} -> term
      {:error, _reason} -> inspect(term)
    end
  end
end
