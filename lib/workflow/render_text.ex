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

  defp apply_formatter(%Template.Hole{op: :path, args: %{pointer: pointer}}, value),
    do: {:ok, json_pointer_get(value, pointer)}

  defp apply_formatter(%Template.Hole{op: :flatten, args: %{pointer: pointer}}, value),
    do: {:ok, value |> json_pointer_get(pointer) |> flatten_value()}

  defp apply_formatter(%Template.Hole{op: :count, args: %{pointer: pointer}}, value),
    do: {:ok, value |> json_pointer_get(pointer) |> count_value()}

  defp apply_formatter(%Template.Hole{op: :numbered_findings, args: %{pointer: pointer}}, value),
    do: {:ok, value |> json_pointer_get(pointer) |> numbered_findings()}

  defp apply_formatter(%Template.Hole{op: :truncate, args: %{max_bytes: max_bytes}}, value),
    do: {:ok, value |> to_text() |> truncate_utf8(max_bytes)}

  defp to_text(text) when is_binary(text), do: text
  defp to_text(other), do: inspect(other)

  defp json_pointer_get(value, ""), do: value

  defp json_pointer_get(value, <<"/", tokens::binary>>) do
    tokens
    |> String.split("/", trim: false)
    |> Enum.reduce_while(value, fn token, current ->
      case pointer_step(current, decode_pointer_token(token)) do
        {:ok, next} -> {:cont, next}
        :error -> {:halt, nil}
      end
    end)
  end

  defp json_pointer_get(_value, _invalid_pointer), do: nil

  defp decode_pointer_token(token) do
    token
    |> String.replace("~1", "/")
    |> String.replace("~0", "~")
  end

  defp pointer_step(map, token) when is_map(map) do
    case Map.fetch(map, token) do
      {:ok, value} -> {:ok, value}
      :error -> fetch_atom_key(map, token)
    end
  end

  defp pointer_step(list, token) when is_list(list) do
    with true <- Regex.match?(~r/\A[0-9]+\z/, token),
         index = String.to_integer(token),
         true <- index < length(list) do
      {:ok, Enum.at(list, index)}
    else
      _out_of_bounds -> :error
    end
  end

  defp pointer_step(_value, _token), do: :error

  defp fetch_atom_key(map, token) do
    Enum.find_value(map, :error, fn
      {key, value} when is_atom(key) ->
        if Atom.to_string(key) == token, do: {:ok, value}

      _entry ->
        false
    end)
  end

  defp flatten_value(list) when is_list(list), do: Enum.flat_map(list, &flatten_value/1)
  defp flatten_value(value), do: [value]

  defp count_value(nil), do: 0
  defp count_value(list) when is_list(list), do: length(list)
  defp count_value(map) when is_map(map), do: map_size(map)
  defp count_value(_value), do: 1

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
    case Map.fetch(map, field) do
      {:ok, value} -> value
      :error -> atom_finding_field(map, field)
    end
  end

  defp atom_finding_field(map, field) do
    case fetch_atom_key(map, field) do
      {:ok, value} -> value
      :error -> ""
    end
  end

  defp truncate_utf8(binary, max_bytes) when byte_size(binary) <= max_bytes, do: binary

  defp truncate_utf8(binary, max_bytes) do
    binary
    |> binary_part(0, max_bytes)
    |> trim_invalid_utf8()
  end

  defp trim_invalid_utf8(binary) do
    cond do
      String.valid?(binary) -> binary
      byte_size(binary) == 0 -> ""
      true -> binary |> binary_part(0, byte_size(binary) - 1) |> trim_invalid_utf8()
    end
  end
end
