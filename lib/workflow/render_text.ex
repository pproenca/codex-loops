defmodule Workflow.RenderText do
  @moduledoc """
  Deterministic prompt rendering over literal fragments and journal-bound values.

  The rendering algorithm is intentionally oblivious to where a value came from:
  compile-time literals and already-committed runtime results both lower to the
  same fragment list and are rendered by the same pure fold.
  """

  alias Workflow.BoundList
  alias Workflow.BoundValue
  alias Workflow.Event
  alias Workflow.Journal
  alias Workflow.JSONPointer
  alias Workflow.JSONValue
  alias Workflow.Template

  @type part ::
          {:text, String.t()}
          | {:literal, term()}
          | {:bound_value, Workflow.Node.binding_ref()}
          | {:bound_list, Workflow.Node.binding_ref()}
          | {:formatter, Template.Hole.t(), part()}

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

  defp render_part({:formatter, %Template.Hole{} = hole, value_part}, events) do
    with {:ok, value} <- materialize_part(value_part, events),
         {:ok, formatted} <- apply_formatter(hole, value) do
      {:ok, to_text(formatted)}
    end
  end

  defp materialize_part({:text, text}, _events), do: {:ok, text}
  defp materialize_part({:literal, literal}, _events), do: {:ok, literal}
  defp materialize_part({:bound_value, ref}, events), do: BoundValue.fold(events, ref)
  defp materialize_part({:bound_list, ref}, events), do: BoundList.fold(events, ref)

  defp apply_formatter(%Template.Hole{formatter: {:path, pointer}}, value), do: {:ok, pointer_value(value, pointer)}

  defp apply_formatter(%Template.Hole{formatter: {:flatten, pointer}}, value),
    do: {:ok, value |> pointer_value(pointer) |> flatten_value()}

  defp apply_formatter(%Template.Hole{formatter: {:count, pointer}}, value),
    do: {:ok, value |> pointer_value(pointer) |> JSONValue.count()}

  defp apply_formatter(%Template.Hole{formatter: {:numbered_findings, pointer}}, value),
    do: {:ok, value |> pointer_value(pointer) |> numbered_findings()}

  defp apply_formatter(%Template.Hole{formatter: {:truncate, max_bytes}}, value),
    do: {:ok, value |> to_text() |> truncate_utf8(max_bytes)}

  defp to_text(text) when is_binary(text), do: text
  defp to_text(other), do: inspect(other)

  defp pointer_value(value, pointer) do
    case JSONPointer.resolve(value, pointer) do
      {:present, resolved} -> resolved
      :missing -> nil
    end
  end

  defp flatten_value(list) when is_list(list), do: Enum.flat_map(list, &flatten_value/1)
  defp flatten_value(value), do: [value]

  defp numbered_findings(value) do
    value
    |> flatten_value()
    |> Enum.with_index(1)
    |> Enum.map_join("\n", fn {item, index} -> numbered_finding(item, index) end)
  end

  defp numbered_finding(map, index) when is_map(map) do
    id = finding_field(map, "id")
    issue = finding_field(map, "issue")
    fix = finding_field(map, "fix")

    "#{index}. [#{to_text(id)}] #{to_text(issue)}\n   Fix: #{to_text(fix)}"
  end

  defp numbered_finding(item, index), do: "#{index}. #{to_text(item)}"

  defp finding_field(map, field) do
    case JSONPointer.resolve(map, "/" <> field) do
      {:present, value} -> value
      :missing -> ""
    end
  end

  defp truncate_utf8(binary, max_bytes) when byte_size(binary) <= max_bytes, do: binary

  defp truncate_utf8(binary, max_bytes) do
    binary
    |> binary_part(0, max_bytes)
    |> trim_invalid_utf8()
    |> :binary.copy()
  end

  defp trim_invalid_utf8(binary) do
    cond do
      String.valid?(binary) -> binary
      byte_size(binary) == 0 -> ""
      true -> binary |> binary_part(0, byte_size(binary) - 1) |> trim_invalid_utf8()
    end
  end
end
