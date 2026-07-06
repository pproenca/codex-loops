defmodule Workflow.Provider.Codex do
  @moduledoc """
  The real provider: each agent turn shells out to the Codex CLI's one-shot,
  non-interactive entrypoint — `codex exec --experimental-json` — through the
  `Workflow.Containment` seam (the only place an external process runs). The prompt
  is fed on stdin; a schema-backed turn additionally writes the JSON schema to a
  temp file passed as `--output-schema`, so Codex constrains its final message to
  that shape. This is the same protocol the official `@openai/codex-sdk` speaks.

  `codex exec` streams JSONL `ThreadEvent`s to stdout and **exits after the single
  turn** (that is what makes it a genuine one-shot line protocol, unlike the
  long-lived `app-server`). This provider folds that stream into `{result, usage}`:
  the last `agent_message` item is the final response — decoded as JSON for a schema
  turn, returned as text otherwise — and the `turn.completed` event carries token
  usage.

  It is a **pure port swap** for the mock — it satisfies the exact
  `Workflow.Provider` contract the interpreter already drives, so selecting `:codex`
  changes no core, writer, or fold code. It returns the backend's *raw* output; it
  does not validate against the schema. Structured-output policy — validate, retry
  on rejection, fail closed — lives in the writer, so a schema turn against this
  provider honours the same fail-closed retry as the mock.

  ## Fail on backend fault, don't fabricate

  The `Workflow.Provider` callback has no error channel: a turn either produces an
  `{:ok, result, usage}` or it doesn't happen. So a containment failure (non-zero
  exit, timeout) or a `turn.failed`/`error` event raises here, crashing the live
  writer — the run's monitor observes the real reason and no phantom result is ever
  journaled. Let it crash.
  """
  @behaviour Workflow.Provider

  alias Workflow.Containment
  alias Workflow.Provider.Usage

  @exec_args ["exec", "--experimental-json", "--skip-git-repo-check"]

  @impl true
  def run_agent(prompt, schema, _key, opts) do
    {command, schema_file} = command(opts, schema)

    try do
      case Containment.run_turn(prompt, command: command, timeout: Keyword.get(opts, :timeout, :infinity)) do
        {:ok, stdout} -> parse_turn(stdout, schema)
        {:error, reason} -> raise "codex turn failed: #{inspect(reason)}"
      end
    after
      schema_file && File.rm(schema_file)
    end
  end

  @doc """
  The production default backend: the real `codex` binary's one-shot
  `exec --experimental-json` entrypoint. Overridable per run via
  `command: {path, args}` (the seam a test uses to point at a hermetic stub).
  """
  @spec default_command() :: {String.t(), [String.t()]}
  def default_command do
    path =
      System.find_executable("codex") ||
        raise "no `codex` executable on PATH; pass `command: {path, args}` to select a backend"

    {path, @exec_args}
  end

  # Full one-shot command for this turn: the base `codex exec` invocation (or an
  # injected backend, e.g. a test stub) plus a per-turn `--output-schema` file when
  # the turn is schema-backed. Returns the temp schema file so the caller can clean
  # it up after the turn.
  defp command(opts, nil), do: {base_command(opts), nil}

  defp command(opts, schema) do
    file = write_schema(schema)
    {path, args} = base_command(opts)
    {{path, args ++ ["--output-schema", file]}, file}
  end

  defp base_command(opts), do: Keyword.get(opts, :command) || default_command()

  defp write_schema(schema) do
    path = Path.join(System.tmp_dir!(), "codex_schema_#{System.unique_integer([:positive])}.json")
    File.write!(path, JSON.encode!(schema))
    path
  end

  # Fold the `codex exec` JSONL stream into {result, usage}. A `turn.failed` or a
  # stream-level `error` event is a real backend fault and raises.
  defp parse_turn(stdout, schema) do
    events = stdout |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)
    Enum.each(events, &raise_on_failure/1)
    {:ok, shape(final_message(events), schema), turn_usage(events)}
  end

  defp raise_on_failure(%{"type" => "turn.failed", "error" => %{"message" => message}}),
    do: raise("codex turn failed: #{message}")

  defp raise_on_failure(%{"type" => "error", "message" => message}),
    do: raise("codex turn failed: #{message}")

  defp raise_on_failure(_event), do: :ok

  defp final_message(events) do
    Enum.reduce(events, "", fn
      %{"type" => "item.completed", "item" => %{"type" => "agent_message", "text" => text}}, _acc ->
        text

      _event, acc ->
        acc
    end)
  end

  # Schemaless: the final response is free text. Schema-backed: it is a JSON document
  # matching the schema, so decode it to the term the writer validates (a text that
  # fails to decode is returned as-is, and the writer's validation rejects it).
  defp shape(text, nil), do: text

  defp shape(text, _schema) do
    case JSON.decode(text) do
      {:ok, value} -> value
      {:error, _reason} -> text
    end
  end

  defp turn_usage(events) do
    reported =
      Enum.reduce(events, %{}, fn
        %{"type" => "turn.completed", "usage" => usage}, _acc -> usage
        _event, acc -> acc
      end)

    input = Map.get(reported, "input_tokens", 0)
    output = Map.get(reported, "output_tokens", 0)
    %Usage{input_tokens: input, output_tokens: output, total_tokens: input + output}
  end
end
