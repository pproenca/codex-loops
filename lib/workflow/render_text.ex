defmodule Workflow.RenderText do
  @moduledoc """
  Deterministic prompt rendering over literal fragments and journal-bound values.

  The rendering algorithm is intentionally oblivious to where a value came from:
  compile-time literals and already-committed runtime results both lower to the
  same fragment list and are rendered by the same pure fold.
  """

  alias Workflow.{Journal, Event, BoundValue, BoundList}

  @type part ::
          {:text, String.t()}
          | {:literal, term()}
          | {:bound_value, Workflow.Node.binding_ref()}
          | {:bound_list, Workflow.Node.binding_ref()}

  @type result :: {:ok, String.t()} | {:error, term()}

  @spec of(String.t(), [part()]) :: result()
  def of(run_id, parts), do: run_id |> Journal.fold() |> fold(parts)

  @spec fold([Event.t()], [part()]) :: result()
  def fold(events, parts) do
    parts
    |> Enum.reduce_while({:ok, []}, fn part, {:ok, acc} ->
      case render_part(part, events) do
        {:ok, chunk} -> {:cont, {:ok, [acc, chunk]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, chunks} -> {:ok, IO.iodata_to_binary(chunks)}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec render!([Event.t()], [part()]) :: String.t()
  def render!(events, parts) do
    case fold(events, parts) do
      {:ok, rendered} -> rendered
      {:error, reason} -> raise ArgumentError, "unable to render text: #{inspect(reason)}"
    end
  end

  defp render_part({:text, text}, _events) when is_binary(text), do: {:ok, text}
  defp render_part({:literal, literal}, _events), do: {:ok, to_text(literal)}

  defp render_part({:bound_value, ref}, events) do
    case BoundValue.fold(events, ref) do
      {:ok, value} -> {:ok, to_text(value)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp render_part({:bound_list, ref}, events) do
    case BoundList.fold(events, ref) do
      {:ok, list} -> {:ok, inspect(list)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp to_text(text) when is_binary(text), do: text
  defp to_text(other), do: inspect(other)
end
