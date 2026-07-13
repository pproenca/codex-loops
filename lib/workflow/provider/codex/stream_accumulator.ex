defmodule Workflow.Provider.Codex.StreamAccumulator do
  @moduledoc false

  alias Workflow.JSONValue
  alias Workflow.Provider.Activity
  alias Workflow.Provider.Codex.Event
  alias Workflow.Provider.Codex.EventEffect
  alias Workflow.Provider.Codex.EventEffect.Value, as: Effect
  alias Workflow.Provider.Usage

  @type t :: %__MODULE__{
          schema: Workflow.Schema.t() | nil,
          activity_sink: (Activity.t() -> non_neg_integer()) | nil,
          final_message: String.t() | nil,
          usage: Usage.t() | nil,
          activity_rev: [Activity.t()],
          failure: {atom(), map()} | nil
        }

  defstruct schema: nil,
            activity_sink: nil,
            final_message: nil,
            usage: nil,
            activity_rev: [],
            failure: nil

  @spec new(map() | nil, (Activity.t() -> non_neg_integer()) | nil) :: t()
  def new(schema, activity_sink), do: %__MODULE__{schema: schema, activity_sink: activity_sink}

  @spec observe_line(t(), String.t()) :: t()
  def observe_line(%__MODULE__{} = acc, line) when is_binary(line) do
    case JSON.decode(line) do
      {:ok, event} when is_map(event) ->
        observe_event(acc, Event.normalize(event))

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
          {:ok, term(), Usage.t(), [Activity.t()]}
          | {:error, {:provider_failure, atom(), map(), Usage.t() | nil, [Activity.t()]}}
  def finish(%__MODULE__{failure: {kind, detail}} = acc) do
    {:error, {:provider_failure, kind, detail, acc.usage, activity(acc)}}
  end

  def finish(%__MODULE__{final_message: nil} = acc) do
    {:error,
     {:provider_failure, :backend, %{"message" => "codex stream completed without a final assistant message"}, acc.usage,
      activity(acc)}}
  end

  def finish(%__MODULE__{} = acc) do
    {:ok, shape(acc.final_message, acc.schema), acc.usage || %Usage{}, activity(acc)}
  end

  @spec partial(t()) :: {Usage.t() | nil, [Activity.t()]}
  def partial(%__MODULE__{} = acc), do: {acc.usage, activity(acc)}

  defp observe_event(%__MODULE__{} = acc, event) do
    %Effect{failure: failure, final_message: final_message, usage: usage, activity: entries} =
      EventEffect.effect(event)

    acc
    |> maybe_put_failure(failure)
    |> maybe_put_final_message(final_message)
    |> maybe_put_usage(usage)
    |> put_activity(entries)
  end

  defp maybe_put_failure(acc, nil), do: acc
  defp maybe_put_failure(acc, {kind, detail}), do: put_failure(acc, kind, detail)

  defp put_failure(%__MODULE__{failure: nil} = acc, kind, detail), do: %{acc | failure: {kind, detail}}
  defp put_failure(%__MODULE__{} = acc, _kind, _detail), do: acc

  defp maybe_put_final_message(acc, nil), do: acc
  defp maybe_put_final_message(acc, final_message), do: %{acc | final_message: final_message}

  defp maybe_put_usage(acc, nil), do: acc
  defp maybe_put_usage(acc, usage), do: %{acc | usage: usage}

  defp put_activity(acc, entries) do
    activity_rev =
      Enum.reduce(entries, acc.activity_rev, fn entry, activity_rev ->
        [emit_activity(acc.activity_sink, entry) | activity_rev]
      end)

    %{acc | activity_rev: activity_rev}
  end

  defp emit_activity(nil, %Activity{} = entry), do: entry

  defp emit_activity(sink, %Activity{} = entry) when is_function(sink, 1) do
    Activity.with_index(entry, sink.(entry))
  end

  defp shape(text, nil), do: text

  defp shape(text, _schema) do
    case JSON.decode(text) do
      {:ok, value} -> JSONValue.copy(value)
      {:error, _reason} -> text
    end
  end

  defp truncate(text, limit) do
    if String.length(text) <= limit,
      do: :binary.copy(text),
      else: :binary.copy(String.slice(text, 0, limit)) <> "..."
  end

  defp activity(%__MODULE__{activity_rev: activity_rev}), do: Enum.reverse(activity_rev)
end
