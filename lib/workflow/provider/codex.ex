defmodule Workflow.Provider.Codex do
  @moduledoc """
  The real provider: each agent turn shells out to the Codex CLI's one-shot,
  non-interactive entrypoint — `codex exec --json` — through the
  `Workflow.Containment` seam (the only place an external process runs). The prompt
  is fed on stdin; a schema-backed turn additionally writes the JSON schema to a
  temp file passed as `--output-schema`, so Codex constrains its final message to
  that shape. This is the same protocol the official `@openai/codex-sdk` speaks.

  `codex exec` streams JSONL `ThreadEvent`s to stdout and **exits after the single
  turn** (that is what makes it a genuine one-shot line protocol, unlike the
  long-lived `app-server`). This provider folds that stream into `{result, usage}`
  while also exposing lifecycle, tool/reasoning, and assistant-output items to the
  run's realtime activity sink. The last `agent_message` item is the final response
  — decoded as JSON for a schema turn, returned as text otherwise — and the
  `turn.completed` event carries token usage.

  It is a **pure port swap** for the mock — it satisfies the exact
  `Workflow.Provider` contract the interpreter already drives, so selecting `:codex`
  changes no core, writer, or fold code. It returns the backend's *raw* output; it
  does not validate against the schema. Structured-output policy — validate, retry
  on rejection, fail closed — lives in the writer, so a schema turn against this
  provider honours the same fail-closed retry as the mock.

  ## Fail on backend fault, don't fabricate

  A containment timeout is an expected provider failure: the backend missed the
  caller's configured deadline, but the run writer can journal that as
  `agent_failed` with a stable `:timeout` kind. Codex protocol failures such as
  `turn.failed`, stream-level `error`, malformed JSONL, or a missing final
  assistant message become `:backend` provider failures, so no phantom result is
  ever journaled.
  """
  @behaviour Workflow.Provider

  alias Workflow.Containment
  alias Workflow.Provider.Codex.StreamAccumulator
  alias Workflow.Schema

  @base_exec_args [
    "exec",
    "--json",
    "--dangerously-bypass-approvals-and-sandbox",
    "--skip-git-repo-check"
  ]

  @timeout_detail %{"message" => "codex turn timed out"}
  @default_timeout 30 * 60 * 1_000

  @impl true
  def run_agent(prompt, schema, _key, opts) do
    schema = schema && Schema.new(schema)

    case command(opts, schema) do
      {:ok, {command, schema_file}} ->
        accumulator = new_accumulator(schema, Keyword.get(opts, :activity_sink))

        try do
          case Containment.run_turn(prompt,
                 command: command,
                 timeout: Keyword.get(opts, :timeout, @default_timeout),
                 line_acc: accumulator,
                 on_line: &StreamAccumulator.observe_line/2
               ) do
            {:ok, _stdout, accumulator} ->
              finish_accumulator(accumulator)

            {:error, :timeout, accumulator} ->
              {usage, activity} = StreamAccumulator.partial(accumulator)
              {:error, {:provider_failure, :timeout, @timeout_detail, usage, activity}}

            {:error, :input_limit, accumulator} ->
              {usage, activity} = StreamAccumulator.partial(accumulator)

              {:error,
               {:provider_failure, :model_limit, %{"message" => "codex prompt exceeded the containment input limit"},
                usage, activity}}

            {:error, :output_limit, accumulator} ->
              {usage, activity} = StreamAccumulator.partial(accumulator)

              {:error,
               {:provider_failure, :backend, %{"message" => "codex output exceeded the containment limit"}, usage,
                activity}}

            {:error, {:backend_exit, status, output}, _accumulator} when status in [126, 127] ->
              {:error, unavailable_failure(backend_start_message(status, output))}

            {:error, {:backend_exit, status, output}, accumulator} ->
              case finish_accumulator(accumulator) do
                {:error, {:provider_failure, :backend, _detail, _usage, _activity} = failure} ->
                  {:error, failure}

                {:ok, _result, usage, activity} ->
                  {:error,
                   {:provider_failure, :backend, %{"message" => backend_exit_message(status, output)}, usage, activity}}
              end
          end
        after
          schema_file && File.rm(schema_file)
        end

      {:error, failure} ->
        {:error, failure}
    end
  end

  @doc """
  The production default backend: the real `codex` binary's one-shot
  `exec --json` entrypoint. Overridable per run via
  `command: {path, args}` (the seam a test uses to point at a hermetic stub).
  The native composition root injects a validated absolute Codex path into
  application configuration before the scheduler boots. This provider never
  discovers commands through `PATH` or process environment.
  """
  @spec default_command() :: {String.t(), [String.t()]}
  def default_command do
    case default_command_result() do
      {:ok, command} ->
        command

      {:error, {:provider_failure, :unavailable, detail, _usage, _activity}} ->
        raise detail["message"]
    end
  end

  # Full one-shot command for this turn: the base `codex exec` invocation (or an
  # injected backend, e.g. a test stub) plus a per-turn `--output-schema` file when
  # the turn is schema-backed. Returns the temp schema file so the caller can clean
  # it up after the turn.
  defp command(opts, nil) do
    with {:ok, command} <- base_command(opts), do: {:ok, {command, nil}}
  end

  defp command(opts, schema) do
    with {:ok, {path, args}} <- base_command(opts) do
      file = write_schema(schema)
      {:ok, {{path, args ++ ["--output-schema", file]}, file}}
    end
  end

  defp base_command(opts) do
    case Keyword.fetch(opts, :command) do
      {:ok, command} -> {:ok, command}
      :error -> default_command_result()
    end
  end

  defp default_command_result do
    case Application.fetch_env(:codex_loops, :codex_command) do
      {:ok, {path, prefix_args}} ->
        {:ok, {path, prefix_args ++ exec_args()}}

      :error ->
        {:error, unavailable_failure("Codex command was not configured")}

      {:ok, value} ->
        {:error, unavailable_failure("invalid Codex command configuration: #{inspect(value)}")}
    end
  end

  defp unavailable_failure(message) do
    {:provider_failure, :unavailable,
     %{
       "message" => message,
       "config" => "codex_command",
       "hint" => "Run `codex-loops install --codex /absolute/path/to/codex` to bind a tested Codex command."
     }, nil, []}
  end

  defp backend_start_message(status, output) do
    detail =
      output
      |> String.trim()
      |> truncate(180)

    case detail do
      "" -> "codex command failed to start with exit status #{status}"
      _text -> "codex command failed to start with exit status #{status}: #{detail}"
    end
  end

  defp backend_exit_message(status, output) do
    detail = output |> String.trim() |> truncate(180)

    case detail do
      "" -> "codex command exited with status #{status}"
      _text -> "codex command exited with status #{status}: #{detail}"
    end
  end

  defp exec_args do
    case Application.get_env(:codex_loops, :codex_model) do
      model when is_binary(model) and model != "" -> @base_exec_args ++ ["--model", model]
      _unset -> @base_exec_args
    end
  end

  defp new_accumulator(schema, activity_sink), do: StreamAccumulator.new(schema, activity_sink)
  defp finish_accumulator(accumulator), do: StreamAccumulator.finish(accumulator)

  defp write_schema(schema) do
    path = Path.join(System.tmp_dir!(), "codex_schema_#{System.unique_integer([:positive])}.json")
    File.write!(path, JSON.encode!(Schema.strict_map(schema)))
    path
  end

  defp truncate(text, limit) do
    if String.length(text) <= limit, do: text, else: String.slice(text, 0, limit) <> "..."
  end
end
