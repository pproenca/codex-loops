defmodule Workflow.CLI do
  @moduledoc """
  The `agent-loops` command surface.

  Seven commands over the journal-backed runtime: `validate`, `run` (alias
  `workflow`), `test`, `resume`, `status`, `inspect`, and `list`. Everything the CLI
  reports about a run is a **pure fold over the journal** — `status`, `inspect`, and
  `list` never consult process state, they project `Workflow.Status`/`Workflow.Event`
  folds — so the read surface can never disagree with the source of truth.

  ## The two contracts

  * **Exit codes.** Every outcome maps to exactly one code via `Workflow.CLI.Error`:
    `0` ok · `2` usage · `4` provider config · `6` validation/budget · `8` malformed
    structured output · `130` killed · `1` other. The error's `code` is the single
    source for both the exit status and the JSON error object, so they cannot drift.
  * **JSON discipline.** Under `--json`, stdout carries **exactly one** final payload
    — a JSON object that always has a `command` field. Progress/warnings go to
    stderr; on failure the **last stderr line** is a single-line JSON error object.
    Without `--json` the same data renders as human-readable text.

  ## Testable seam

  `exec/1` takes an argv list, performs the command, prints the envelope, and
  returns the integer exit code — so behaviour is asserted at the real CLI seam
  (argv in, envelope + exit code out) without shelling out. `main/1` is the escript
  entry that simply halts on `exec/1`.
  """

  alias Workflow.{Journal, Status, Event, Run}
  alias Workflow.CLI.Error

  # OptionParser switch types, keyed by the canonical (underscored) option name.
  @switches %{
    run_id: :string,
    provider: :string,
    budget: :integer,
    limit: :integer,
    event_limit: :integer
  }

  @help """
  agent-loops — journal-backed workflow runner

    validate <script> [--json]
        Run the compile-time gate on a workflow script. Exit 6 with rustc-style
        findings if it is outside the combinator vocabulary.

    run <script> [--run-id <id>] [--provider mock|codex] [--budget <n>] [--json]
    workflow <script> ...        (alias of run)
        Compile and execute a workflow to completion. Defaults to the codex provider.

    test <script> [--run-id <id>] [--budget <n>] [--json]
        Like run, pinned to the offline mock provider.

    resume [<script>] [--run-id <id>] [--provider mock|codex] [--json]
        Resume the selected run (latest if --run-id is omitted). The workflow is
        recovered from the run's journaled script path, or passed explicitly.

    status  [--run-id <id>] [--event-limit <n>] [--json]
    inspect [--run-id <id>] [--json]
    list    [--limit <n>] [--json]
        Read surfaces — pure folds over the journal. Select the latest run when
        --run-id is omitted.

  Exit codes: 0 ok · 2 usage · 4 provider config · 6 validation/budget ·
  8 malformed output · 130 killed · 1 other.
  """

  @doc "Escript entry point: run the command and halt on its exit code."
  @spec main([String.t()]) :: no_return()
  def main(argv), do: System.halt(exec(argv))

  @doc """
  Perform the command described by `argv`, print its result, and return the exit
  code. The real seam a test drives.
  """
  @spec exec([String.t()]) :: non_neg_integer()
  def exec(argv) do
    {:ok, _started} = Application.ensure_all_started(:codex_loops)
    {json?, argv} = pop_json(argv)

    result =
      with :ok <- reject_journal_flag(argv) do
        dispatch(argv)
      end

    emit(result, json?)
  end

  # --- Command routing ---

  defp dispatch(["validate" | rest]), do: validate(rest)
  defp dispatch(["run" | rest]), do: run_cmd("run", rest, default_provider: :codex)
  defp dispatch(["workflow" | rest]), do: run_cmd("run", rest, default_provider: :codex)
  defp dispatch(["test" | rest]), do: run_cmd("test", rest, force_provider: :mock)
  defp dispatch(["resume" | rest]), do: resume(rest)
  defp dispatch(["status" | rest]), do: status(rest)
  defp dispatch(["inspect" | rest]), do: inspect_cmd(rest)
  defp dispatch(["list" | rest]), do: list(rest)
  defp dispatch(["help" | _rest]), do: {:ok, %{"command" => "help", "text" => @help}}
  defp dispatch([]), do: {:error, Error.new(:usage, "no command given", "try `help`")}

  defp dispatch([cmd | _rest]),
    do: {:error, Error.new(:usage, "unknown command #{inspect(cmd)}", "try `help`")}

  # --- validate ---

  defp validate(argv) do
    with {:ok, _opts, positional} <- parse_opts(argv, []),
         {:ok, path} <- require_script(positional),
         {:ok, tree} <- load_tree(path) do
      {:ok,
       %{
         "command" => "validate",
         "valid" => true,
         "name" => tree.name,
         "nodeCount" => length(tree.nodes),
         "script" => path
       }}
    end
  end

  # --- run / workflow / test ---

  defp run_cmd(command, argv, opts) do
    with {:ok, parsed, positional} <- parse_opts(argv, [:run_id, :provider, :budget]),
         {:ok, path} <- require_script(positional),
         {:ok, tree} <- load_tree(path),
         {:ok, provider} <- resolve_provider(provider_name(parsed, opts)),
         {:ok, budget} <- resolve_budget(parsed) do
      run_opts =
        [provider: provider, budget: budget, script_path: Path.expand(path)]
        |> put_run_id(Keyword.get(parsed, :run_id))

      execute_run(command, tree, run_opts)
    end
  end

  # --- resume ---

  defp resume(argv) do
    with {:ok, parsed, positional} <- parse_opts(argv, [:run_id, :provider]),
         {:ok, run_id} <- select_run(parsed),
         {:ok, tree, path} <- recover_tree(run_id, positional),
         {:ok, provider} <- resolve_provider(provider_name(parsed, default_provider: :codex)) do
      run_opts =
        [run_id: run_id, provider: provider]
        |> then(fn o -> if path, do: Keyword.put(o, :script_path, path), else: o end)

      execute_run("resume", tree, run_opts)
    end
  end

  # Prefer an explicitly-passed script; otherwise recover the one journaled at start.
  defp recover_tree(_run_id, [path | _]) do
    with {:ok, tree} <- load_tree(path), do: {:ok, tree, Path.expand(path)}
  end

  defp recover_tree(run_id, []) do
    case run_script_path(run_id) do
      nil ->
        {:error,
         Error.new(:usage, "cannot resume #{run_id}: no script recorded",
           "pass the workflow script path"
         )}

      path ->
        with {:ok, tree} <- load_tree(path), do: {:ok, tree, Path.expand(path)}
    end
  end

  # Drive the run (fresh or resumed) and map its outcome onto the exit-code contract.
  defp execute_run(command, tree, run_opts) do
    case Run.run(tree, run_opts) do
      {:ok, run_id} ->
        {:ok, Map.put(run_projection(run_id), "command", command)}

      {:error, {:malformed_output, address, reason}} ->
        {:error,
         Error.new(
           :malformed_output,
           "structured output failed validation at #{inspect(address)}: #{inspect(reason)}"
         )}

      {:error, {:already_running, _pid}} ->
        {:error, Error.new(:runtime, "a live writer already holds this run")}

      {:error, {:run_crashed, :killed}} ->
        {:error, Error.new(:killed, "run was killed")}

      {:error, {:run_crashed, reason}} ->
        {:error, Error.new(:runtime, "run crashed: #{inspect(reason)}")}

      {:error, reason} ->
        {:error, Error.new(:runtime, "run failed: #{inspect(reason)}")}
    end
  end

  # --- status / inspect / list (pure folds over the journal) ---

  defp status(argv) do
    with {:ok, opts, _positional} <- parse_opts(argv, [:run_id, :event_limit]),
         {:ok, run_id} <- select_run(opts) do
      limit = Keyword.get(opts, :event_limit, 5)

      {:ok,
       run_projection(run_id)
       |> Map.put("command", "status")
       |> Map.put("recentEvents", recent_events(run_id, limit))}
    end
  end

  defp inspect_cmd(argv) do
    with {:ok, opts, _positional} <- parse_opts(argv, [:run_id]),
         {:ok, run_id} <- select_run(opts) do
      {:ok,
       run_projection(run_id)
       |> Map.put("command", "inspect")
       |> Map.put("events", all_events(run_id))}
    end
  end

  defp list(argv) do
    with {:ok, opts, _positional} <- parse_opts(argv, [:limit]) do
      limit = Keyword.get(opts, :limit, 20)

      runs =
        Journal.run_ids()
        # Newest first: run_ids/0 yields oldest-created first.
        |> Enum.reverse()
        |> Enum.take(limit)
        |> Enum.map(&run_summary/1)

      {:ok, %{"command" => "list", "runs" => runs, "count" => length(runs)}}
    end
  end

  # --- Run selection: explicit --run-id, else the latest run ---

  defp select_run(opts) do
    case Keyword.get(opts, :run_id) do
      nil ->
        case Journal.latest_run_id() do
          nil ->
            {:error,
             Error.new(:usage, "no runs found", "run a workflow first, or pass --run-id")}

          id ->
            {:ok, id}
        end

      id ->
        if id in Journal.run_ids(),
          do: {:ok, id},
          else: {:error, Error.new(:usage, "unknown run #{inspect(id)}")}
    end
  end

  # --- Journal projections (all pure folds) ---

  defp run_projection(run_id) do
    s = Status.of(run_id)

    %{
      "runId" => run_id,
      "state" => Atom.to_string(s.state),
      "treeName" => s.tree_name,
      "phase" => s.phase,
      "logs" => s.logs,
      "agentCount" => length(s.agents),
      "eventCount" => s.event_count,
      "usage" => %{
        "inputTokens" => s.usage.input_tokens,
        "outputTokens" => s.usage.output_tokens,
        "totalTokens" => s.usage.total_tokens
      },
      "result" => jsonable(s.result),
      "failure" => encode_failure(s.failure)
    }
  end

  defp run_summary(run_id) do
    s = Status.of(run_id)

    %{
      "runId" => run_id,
      "state" => Atom.to_string(s.state),
      "treeName" => s.tree_name,
      "eventCount" => s.event_count
    }
  end

  defp recent_events(run_id, limit),
    do: run_id |> Journal.fold() |> Enum.take(-limit) |> Enum.map(&event_projection/1)

  defp all_events(run_id),
    do: run_id |> Journal.fold() |> Enum.map(&event_projection/1)

  defp event_projection(%Event{seq: seq, type: type, payload: payload}) do
    %{"seq" => seq, "type" => Atom.to_string(type)}
    |> put_present("address", Map.get(payload, :address))
  end

  defp run_script_path(run_id) do
    case Enum.find(Journal.fold(run_id), &(&1.type == :run_started)) do
      nil -> nil
      event -> Map.get(event.payload, :script_path)
    end
  end

  defp encode_failure(nil), do: nil

  defp encode_failure(%{address: address, attempts: attempts, reason: reason}),
    do: %{"address" => address, "attempts" => attempts, "reason" => inspect(reason)}

  # Keep JSON-encodable terms as-is; fall back to an inspected string for anything
  # Jason cannot encode (e.g. a tuple return literal), so the envelope always encodes.
  defp jsonable(term) do
    case Jason.encode(term) do
      {:ok, _json} -> term
      {:error, _reason} -> inspect(term)
    end
  end

  # --- Workflow loading: the same compile-time gate as execution (#2) ---

  defp load_tree(path) do
    if File.regular?(path),
      do: compile_tree(path),
      else: {:error, Error.new(:usage, "workflow script not found: #{path}")}
  end

  defp compile_tree(path) do
    modules = Code.compile_file(path)

    case Enum.find(modules, fn {mod, _bin} -> function_exported?(mod, :__workflow__, 1) end) do
      {mod, _bin} ->
        {:ok, mod.__workflow__(:tree)}

      nil ->
        {:error,
         Error.new(:validation, "no workflow defined in #{path}",
           "define one with `use Workflow` and a `workflow \"name\" do ... end` block"
         )}
    end
  rescue
    # The `workflow` macro raises this from the compile-time gate; surface its
    # rustc-style findings as a located validation failure (exit 6).
    e in Workflow.CompileError -> {:error, Error.new(:validation, Exception.message(e))}
  end

  # --- Option/argument parsing ---

  defp parse_opts(argv, allowed) do
    strict = Enum.map(allowed, &{&1, Map.fetch!(@switches, &1)})

    case OptionParser.parse(argv, strict: strict) do
      {opts, positional, []} ->
        {:ok, opts, positional}

      {_opts, _positional, [{flag, _value} | _rest]} ->
        {:error, Error.new(:usage, "unrecognized or malformed option #{flag}")}
    end
  end

  defp require_script([path | _rest]), do: {:ok, path}
  defp require_script([]), do: {:error, Error.new(:usage, "missing workflow script path")}

  defp resolve_provider("mock"), do: {:ok, {Workflow.Provider.Mock, []}}
  defp resolve_provider("codex"), do: {:ok, {Workflow.Provider.Codex, []}}

  defp resolve_provider(other),
    do:
      {:error,
       Error.new(:provider_config, "unknown provider #{inspect(other)}", "choose mock or codex")}

  # `test` pins the provider; otherwise honour --provider, defaulting per command.
  defp provider_name(parsed, opts) do
    case Keyword.get(opts, :force_provider) do
      nil -> Keyword.get(parsed, :provider, Atom.to_string(Keyword.fetch!(opts, :default_provider)))
      forced -> Atom.to_string(forced)
    end
  end

  defp resolve_budget(parsed) do
    case Keyword.fetch(parsed, :budget) do
      :error -> {:ok, nil}
      {:ok, n} when is_integer(n) and n > 0 -> {:ok, n}
      {:ok, _bad} -> {:error, Error.new(:usage, "--budget must be a positive integer")}
    end
  end

  defp put_run_id(opts, nil), do: opts
  defp put_run_id(opts, run_id), do: Keyword.put(opts, :run_id, run_id)

  # --- argv preprocessing ---

  # `--json` is a global flag: strip it from anywhere in argv before command parsing.
  defp pop_json(argv) do
    {json?, rev} =
      Enum.reduce(argv, {false, []}, fn
        "--json", {_json?, acc} -> {true, acc}
        arg, {json?, acc} -> {json?, [arg | acc]}
      end)

    {json?, Enum.reverse(rev)}
  end

  defp reject_journal_flag(argv) do
    if Enum.any?(argv, &String.starts_with?(&1, "--journal")),
      do: {:error, Error.new(:usage, "--journal was removed; use --run-id")},
      else: :ok
  end

  # --- Output: JSON discipline vs. human rendering ---

  defp emit({:ok, envelope}, true) do
    IO.puts(Jason.encode!(envelope))
    0
  end

  defp emit({:ok, envelope}, false) do
    IO.puts(render_human(envelope))
    0
  end

  defp emit({:error, %Error{} = error}, true) do
    IO.puts(:stderr, Error.to_json(error))
    Error.exit_code(error)
  end

  defp emit({:error, %Error{} = error}, false) do
    IO.puts(:stderr, human_error(error))
    Error.exit_code(error)
  end

  defp human_error(%Error{message: message, hint: nil}), do: "error: #{message}"
  defp human_error(%Error{message: message, hint: hint}), do: "error: #{message}\n  hint: #{hint}"

  defp render_human(%{"command" => "help", "text" => text}), do: text

  defp render_human(%{"command" => "validate"} = e),
    do: "valid — #{e["name"]} (#{e["nodeCount"]} nodes)\n  #{e["script"]}"

  defp render_human(%{"command" => "list"} = e) do
    rows =
      Enum.map(e["runs"], fn r ->
        "  #{r["runId"]}  #{r["state"]}  #{r["treeName"]}  (#{r["eventCount"]} events)"
      end)

    Enum.join(["#{e["count"]} run(s)" | rows], "\n")
  end

  defp render_human(%{"command" => "inspect"} = e) do
    events = Enum.map(e["events"], &event_line/1)
    Enum.join([run_line(e), "events:" | events], "\n")
  end

  defp render_human(%{"command" => "status"} = e) do
    recent = Enum.map(e["recentEvents"], &event_line/1)

    Enum.join(
      [run_line(e), "phase: #{e["phase"]}", "usage: #{e["usage"]["totalTokens"]} tokens", "recent:"]
      |> Kernel.++(recent),
      "\n"
    )
  end

  # run / test / resume
  defp render_human(%{"command" => _command} = e), do: run_line(e)

  defp run_line(e) do
    base = "#{e["command"]}: #{e["runId"]} — #{e["state"]}"

    cond do
      e["failure"] ->
        base <> "\n  failure at #{inspect(e["failure"]["address"])}: #{e["failure"]["reason"]}"

      not is_nil(e["result"]) ->
        base <> "\n  result: #{inspect(e["result"])}"

      true ->
        base
    end
  end

  defp event_line(%{"seq" => seq, "type" => type} = ev),
    do: "  ##{seq}  #{type}#{address_suffix(ev)}"

  defp address_suffix(%{"address" => address}) when is_list(address), do: " #{inspect(address)}"
  defp address_suffix(_ev), do: ""

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)
end
