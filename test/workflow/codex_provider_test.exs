defmodule Workflow.CodexProviderTest do
  @moduledoc """
  The real provider driven through the interpreter over an inert tree, exercising
  external behaviour at the highest seam: `Workflow.Run.run/2` with the `:codex`
  backend selected as a port swap. The backend is a **hermetic stub** — a genuine
  OS subprocess reached through the `Workflow.Containment` boundary — that speaks
  the *exact* line protocol the real `codex exec --json` speaks: it
  reads the prompt on stdin and emits the same JSONL `ThreadEvent` stream
  (`thread.started` / `turn.started` / `item.completed{agent_message}` /
  `turn.completed{usage}`) that the production default parses, then exits `0`. So
  every turn crosses a real process boundary (real `Port`, real stdio, real JSONL,
  real exit status) with no network, over the genuine protocol. Assertions are on
  the committed journal and the folded read model, never on provider internals.

  The production wiring itself (`Provider.Codex.default_command/0` → the real
  `codex` binary's one-shot `exec` entrypoint) is covered separately, without
  spending a live turn.
  """
  use ExUnit.Case, async: true

  alias Workflow.{Run, Journal, Status, Provider}

  # A hermetic stub `codex exec --json`: read the prompt on stdin, emit
  # the real JSONL event stream, exit 0. Output is chosen by argv mode. The `retry`
  # mode alternates invalid→valid across successive invocations via a counter file —
  # exactly how successive real turns differ — so it exercises fail-closed retry.
  @stub_source ~S"""
  [mode | rest] = System.argv()
  prompt = case IO.read(:stdio, :eof) do :eof -> ""; s -> String.trim(s) end

  if mode == "timeout" do
    Process.sleep(500)
    System.halt(0)
  end

  valid = %{"bugs" => [%{"file" => "lib/a.ex", "line" => 3}]}
  invalid = %{"bugs" => "nope"}

  text =
    case mode do
      "echo" -> prompt
      "activity" -> prompt
      "schema_file" ->
        schema_file =
          rest
          |> Enum.chunk_every(2, 1, :discard)
          |> Enum.find_value(fn
            ["--output-schema", file] -> file
            _ -> nil
          end)

        File.read!(schema_file)
      "always_invalid" -> JSON.encode!(invalid)
      "retry" ->
        counter = Enum.at(rest, 0)
        first? = not File.exists?(counter)
        File.write!(counter, "seen")
        JSON.encode!(if first?, do: invalid, else: valid)
    end

  usage =
    case mode do
      "echo" -> %{"input_tokens" => 3, "cached_input_tokens" => 0, "output_tokens" => 5, "reasoning_output_tokens" => 0}
      _ -> %{"input_tokens" => 1, "cached_input_tokens" => 0, "output_tokens" => 1, "reasoning_output_tokens" => 0}
    end

  activity =
    case mode do
      "activity" ->
        [
          %{"type" => "item.completed", "item" => %{"id" => "r1", "type" => "reasoning", "text" => "Read the failing test"}},
          %{"type" => "item.completed", "item" => %{"id" => "c1", "type" => "tool_call", "name" => "shell", "input" => %{"cmd" => "mix test test/workflow/codex_provider_test.exs"}}}
        ]

      _ ->
        []
    end

  for event <- [
        %{"type" => "thread.started", "thread_id" => "t1"},
        %{"type" => "turn.started"}
      ] ++ activity ++ [
        %{"type" => "item.completed", "item" => %{"id" => "i1", "type" => "agent_message", "text" => text}},
        %{"type" => "turn.completed", "usage" => usage}
      ] do
    IO.puts(JSON.encode!(event))
  end
  """

  @bugs_schema %{
    "type" => "object",
    "properties" => %{
      "bugs" => %{
        "type" => "array",
        "items" => %{
          "type" => "object",
          "properties" => %{
            "file" => %{"type" => "string"},
            "line" => %{"type" => "integer"}
          },
          "required" => ["file", "line"]
        }
      }
    },
    "required" => ["bugs"]
  }

  defmodule EchoWorkflow do
    use Workflow

    workflow "codex_echo" do
      agent("say hello")
      return(:ok)
    end
  end

  defmodule SchemaWorkflow do
    use Workflow

    workflow "codex_schema" do
      agent("find bugs",
        schema: %{
          "type" => "object",
          "properties" => %{
            "bugs" => %{
              "type" => "array",
              "items" => %{
                "type" => "object",
                "properties" => %{
                  "file" => %{"type" => "string"},
                  "line" => %{"type" => "integer"}
                },
                "required" => ["file", "line"]
              }
            }
          },
          "required" => ["bugs"]
        }
      )

      return(:ok)
    end
  end

  setup_all do
    path = Path.join(System.tmp_dir!(), "codex_stub_#{System.unique_integer([:positive])}.exs")
    File.write!(path, @stub_source)
    on_exit(fn -> File.rm(path) end)
    %{elixir: System.find_executable("elixir"), stub: path}
  end

  defp run_id, do: "run_#{System.unique_integer([:positive])}"

  defp tmp(suffix),
    do: Path.join(System.tmp_dir!(), "codex_#{suffix}_#{System.unique_integer([:positive])}")

  # Select the codex backend as a port swap, pointed at the hermetic stub in `mode`.
  defp codex(%{elixir: elixir, stub: stub}, mode, extra \\ []),
    do: Provider.select(:codex, command: {elixir, [stub, mode | extra]})

  defp types(id), do: id |> Journal.fold() |> Enum.map(& &1.type)
  defp settled_types(id), do: id |> types() |> Enum.reject(&(&1 == :agent_activity))

  test "--provider codex executes a real agent turn and journals its result + usage", ctx do
    id = run_id()

    assert {:ok, ^id} = Run.run(EchoWorkflow, run_id: id, provider: codex(ctx, "echo"))

    committed = Enum.find(Journal.fold(id), &(&1.type == :agent_committed))

    # The result and usage came back across the real containment boundary as the
    # folded JSONL stream — a schemaless turn's final agent_message is the text, and
    # usage is `input_tokens + output_tokens` from `turn.completed`.
    assert committed.payload.result == "say hello"
    assert committed.payload.usage.total_tokens == 8
    assert committed.payload.address == [0]

    status = Status.of(id)
    assert status.state == :completed
    assert status.usage.total_tokens == 8
    assert settled_types(id) == [:run_started, :agent_committed, :run_completed]
    assert Enum.count(types(id), &(&1 == :agent_activity)) == 2
  end

  test "the production default backend is the real codex exec one-shot entrypoint" do
    # No live turn is spent: this pins the untested production wiring. The default
    # command resolves to the real `codex` binary's one-shot JSONL entrypoint — the
    # protocol the stub above faithfully mimics.
    assert {path,
            [
              "exec",
              "--json",
              "--dangerously-bypass-approvals-and-sandbox",
              "--skip-git-repo-check"
            ]} =
             Workflow.Provider.Codex.default_command()

    assert Path.basename(path) == "codex"
    assert File.exists?(path)
  end

  test "provider selection is a port swap; the interpreter path is unchanged", ctx do
    mock_id = run_id()
    codex_id = run_id()

    # Selection resolves a name to a {module, opts} port — nothing else.
    assert {Workflow.Provider.Mock, []} = Provider.select(:mock, [])
    assert {Workflow.Provider.Codex, command: _} = codex(ctx, "echo")

    assert {:ok, ^mock_id} =
             Run.run(EchoWorkflow, run_id: mock_id, provider: Provider.select(:mock, []))

    assert {:ok, ^codex_id} =
             Run.run(EchoWorkflow, run_id: codex_id, provider: codex(ctx, "echo"))

    # Same inert tree, same interpreter: swapping the backend leaves the committed
    # event shape identical — only the backend module differs.
    assert types(mock_id) == settled_types(codex_id)
    assert Status.of(mock_id).state == Status.of(codex_id).state
  end

  test "codex JSONL stream is normalized into concise committed activity", ctx do
    id = run_id()

    assert {:ok, ^id} = Run.run(EchoWorkflow, run_id: id, provider: codex(ctx, "activity"))

    committed = Enum.find(Journal.fold(id), &(&1.type == :agent_committed))

    assert committed.payload.result == "say hello"

    assert Enum.map(committed.payload.activity, &Map.delete(&1, :activity_index)) == [
             %{
               kind: "reasoning",
               label: "Reasoning",
               summary: "Read the failing test",
               status: "completed"
             },
             %{
               kind: "tool",
               label: "shell",
               summary: "mix test test/workflow/codex_provider_test.exs",
               status: "completed"
             }
           ]

    assert Enum.map(committed.payload.activity, & &1.activity_index) == [2, 3]
  end

  test "containment timeout is an expected provider failure with stable detail", ctx do
    id = run_id()
    key = %Workflow.IdempotencyKey{run_id: id, node_path: [0], iteration: 0}
    {Workflow.Provider.Codex, opts} = codex(ctx, "timeout")
    opts = Keyword.put(opts, :timeout, 100)
    detail = %{"message" => "codex turn timed out"}

    assert {:error, {:provider_failure, :timeout, ^detail, nil, []}} =
             Workflow.Provider.Codex.run_agent("say hello", nil, key, opts)

    assert {:error, {:provider_failure, [0], :timeout, ^detail}} =
             Run.run(EchoWorkflow, run_id: id, provider: {Workflow.Provider.Codex, opts})

    assert settled_types(id) == [:run_started, :agent_failed]

    failed = Enum.find(Journal.fold(id), &(&1.type == :agent_failed))
    assert failed.payload.reason == {:provider_failure, :timeout, detail}
    assert failed.payload.usage == nil
    assert failed.payload.activity == []

    status = Status.of(id)
    assert status.state == :failed
    assert status.failure.reason == {:provider_failure, :timeout, detail}
    assert status.usage.total_tokens == 0

    assert [agent] = status.agents
    assert agent.status == :failed
    assert agent.usage == %Provider.Usage{}
    assert agent.activity == []
    assert agent.provider_failure == %{kind: :timeout, detail: detail}
  end

  test "a schema-backed turn against the real provider honours fail-closed retry", ctx do
    id = run_id()
    counter = tmp("retry")
    on_exit(fn -> File.rm(counter) end)

    # The stub rejects the first invocation and corrects on the retry; the writer
    # re-runs the paid turn across the real boundary, so the retry gets fresh output.
    assert {:ok, ^id} =
             Run.run(SchemaWorkflow, run_id: id, provider: codex(ctx, "retry", [counter]))

    assert settled_types(id) == [
             :run_started,
             :agent_attempt_rejected,
             :agent_committed,
             :run_completed
           ]

    committed = Enum.find(Journal.fold(id), &(&1.type == :agent_committed))
    assert committed.payload.result == %{"bugs" => [%{"file" => "lib/a.ex", "line" => 3}]}
    assert Status.of(id).state == :completed
  end

  test "a real turn that never validates fails closed after exhausting retries", ctx do
    id = run_id()

    assert {:error, {:malformed_output, [0], _reason}} =
             Run.run(SchemaWorkflow, run_id: id, provider: codex(ctx, "always_invalid"))

    # Default budget: three paid attempts across the real boundary, then a terminal
    # failure — the same fail-closed contract the mock proves, now end-to-end.
    assert settled_types(id) ==
             [
               :run_started,
               :agent_attempt_rejected,
               :agent_attempt_rejected,
               :agent_attempt_rejected,
               :agent_failed
             ]

    status = Status.of(id)
    assert status.state == :failed
    assert status.failure.attempts == 3
  end

  test "the schema reaches the backend so the schema map is respected" do
    # Sanity: the compiled inert tree carries the raw schema map unchanged, and the
    # provider forwards it as `--output-schema` — the writer, not the provider,
    # decides validity.
    assert [%Workflow.Node.Agent{schema: schema} | _] = SchemaWorkflow.__workflow__(:tree).nodes
    assert schema == @bugs_schema
  end

  test "schemas handed to --output-schema are strict object schemas", ctx do
    schema = %{
      "type" => "object",
      "additionalProperties" => true,
      "properties" => %{
        "items" => %{
          "type" => "array",
          "items" => %{
            "type" => "object",
            "additionalProperties" => true,
            "properties" => %{"name" => %{"type" => "string"}},
            "required" => ["name"]
          }
        }
      },
      "required" => ["items"]
    }

    key = %Workflow.IdempotencyKey{run_id: "schema", node_path: [0], iteration: 0}

    assert {:ok, written, %Provider.Usage{}, _activity} =
             Workflow.Provider.Codex.run_agent(
               "show schema",
               schema,
               key,
               elem(codex(ctx, "schema_file"), 1)
             )

    assert written["additionalProperties"] == false
    assert written["properties"]["items"]["items"]["additionalProperties"] == false
  end
end
