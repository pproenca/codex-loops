defmodule Workflow.CodexProviderTest do
  @moduledoc """
  The real provider driven through the interpreter over an inert tree, exercising
  external behaviour at the highest seam: `Workflow.Run.run/2` with the `:codex`
  backend selected as a port swap. The backend is a **hermetic stub** — a genuine
  OS subprocess owned by the supervised app-server transport. It speaks the same
  JSONL JSON-RPC handshake, request, notification, token-usage, and terminal-turn
  protocol as `codex app-server`. Every turn crosses a real process boundary (real
  `Port`, real stdio, real JSONL) with no network. Assertions are on
  the committed journal and the folded read model, never on provider internals.

  The production wiring itself (`Provider.Codex.default_command/0` → the real
  `codex` binary's `app-server` entrypoint) is covered separately, without
  spending a live turn.
  """
  use ExUnit.Case, async: false

  alias Workflow.Journal
  alias Workflow.Provider.Activity
  alias Workflow.Provider.Codex
  alias Workflow.Provider.Codex.AppServer
  alias Workflow.Provider.Codex.AppServer.TurnRequest
  alias Workflow.Provider.Mock
  alias Workflow.Provider.Usage
  alias Workflow.Run
  alias Workflow.Schema
  alias Workflow.Status
  alias Workflow.Status.ProviderFailure

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
    @moduledoc false

    def tree do
      Workflow.Test.tree!(
        "codex_echo",
        quote do
          agent("say hello")
          return(:ok)
        end,
        __ENV__
      )
    end
  end

  defmodule SchemaWorkflow do
    @moduledoc false

    def tree do
      Workflow.Test.tree!(
        "codex_schema",
        quote do
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
        end,
        __ENV__
      )
    end
  end

  defmodule SemanticSchemaWorkflow do
    @moduledoc false

    def tree do
      Workflow.Test.tree!(
        "codex_schema_semantics",
        quote do
          agent("Findings must cite a concrete file and line.",
            schema: %{
              "type" => "object",
              "properties" => %{
                "prompt" => %{"type" => "string"},
                "hasSchemaFile" => %{"type" => "boolean"}
              },
              "required" => ["prompt", "hasSchemaFile"]
            }
          )

          return(:ok)
        end,
        __ENV__
      )
    end
  end

  setup_all do
    %{python: System.find_executable("python3"), stub: Path.expand("../support/codex_app_server_stub.py", __DIR__)}
  end

  setup do
    AppServer.reset()
    on_exit(&AppServer.reset/0)
    :ok
  end

  defp run_id, do: "run_#{System.unique_integer([:positive])}"

  defp tmp(suffix), do: Path.join(System.tmp_dir!(), "codex_#{suffix}_#{System.unique_integer([:positive])}")

  # Select the codex backend as a port swap, pointed at the hermetic stub in `mode`.
  defp codex(%{python: python, stub: stub}, mode, extra \\ []), do: {Codex, command: {python, [stub, mode | extra]}}

  defp types(id), do: id |> Journal.fold() |> Enum.map(& &1.type)
  defp settled_types(id), do: id |> types() |> Enum.reject(&(&1 in [:agent_started, :agent_activity]))

  defp activity_fields(%Activity{} = activity) do
    activity
    |> Map.from_struct()
    |> Map.delete(:activity_index)
  end

  test "--provider codex executes a real agent turn and journals its result + usage", ctx do
    id = run_id()

    assert {:ok, ^id} = Run.run(EchoWorkflow.tree(), run_id: id, provider: codex(ctx, "echo"))

    committed = Enum.find(Journal.fold(id), &(&1.type == :agent_committed))

    # The result and usage came back across the real app-server JSONL boundary —
    # a schemaless turn's final agent_message is the text, and usage is
    # `input_tokens + output_tokens` from `turn.completed`.
    assert committed.payload.result == "say hello"
    assert committed.payload.usage.total_tokens == 8
    assert committed.payload.address == [0]

    status = Status.of(id)
    assert status.state == :completed
    assert status.usage.total_tokens == 8
    assert settled_types(id) == [:run_started, :agent_committed, :run_completed]
    assert Enum.count(types(id), &(&1 == :agent_activity)) == 3
  end

  test "provider injection is a port swap; the interpreter path is unchanged", ctx do
    mock_id = run_id()
    codex_id = run_id()

    assert {Codex, command: _} = codex(ctx, "echo")

    assert {:ok, ^mock_id} =
             Run.run(EchoWorkflow.tree(), run_id: mock_id, provider: {Mock, []})

    assert {:ok, ^codex_id} =
             Run.run(EchoWorkflow.tree(), run_id: codex_id, provider: codex(ctx, "echo"))

    # Same inert tree, same interpreter: swapping the backend leaves the committed
    # event shape identical — only the backend module differs.
    assert settled_types(mock_id) == settled_types(codex_id)
    assert Status.of(mock_id).state == Status.of(codex_id).state
  end

  test "codex JSONL stream is normalized into concise committed activity", ctx do
    id = run_id()

    assert {:ok, ^id} = Run.run(EchoWorkflow.tree(), run_id: id, provider: codex(ctx, "activity"))

    committed = Enum.find(Journal.fold(id), &(&1.type == :agent_committed))

    assert committed.payload.result == "say hello"

    assert Enum.map(committed.payload.activity, &activity_fields/1) == [
             %{
               kind: "lifecycle",
               label: "Thread started",
               summary: "t1",
               status: :running
             },
             %{kind: "lifecycle", label: "Turn started", summary: nil, status: :running},
             %{
               kind: "reasoning",
               label: "Reasoning",
               summary: "Read the failing test",
               status: :completed
             },
             %{
               kind: "tool",
               label: "shell",
               summary: "mix test test/workflow/codex_provider_test.exs",
               status: :completed
             },
             %{
               kind: "output",
               label: "Assistant",
               summary: "say hello",
               status: :completed
             }
           ]

    assert Enum.map(committed.payload.activity, & &1.activity_index) == [0, 1, 2, 3, 4]
  end

  test "turn.failed prevents successful settlement even after assistant output", ctx do
    id = run_id()
    detail = %{"message" => "codex backend exploded"}
    key = %Workflow.IdempotencyKey{run_id: id, node_path: [0], iteration: 0}
    {Codex, opts} = codex(ctx, "turn_failed")

    assert {:error, {:provider_failure, :backend, ^detail, nil, activity}} =
             Codex.run_agent("say hello", nil, key, opts)

    assert Enum.any?(activity, &(&1.kind == "output" and &1.summary == "partial assistant output"))

    assert {:error, {:provider_failure, [0], :backend, ^detail}} =
             Run.run(EchoWorkflow.tree(), run_id: id, provider: {Codex, opts})

    assert settled_types(id) == [:run_started, :agent_failed]
    refute Enum.any?(Journal.fold(id), &(&1.type == :agent_committed))

    failed = Enum.find(Journal.fold(id), &(&1.type == :agent_failed))
    assert failed.payload.reason == {:provider_failure, :backend, detail}
    assert Enum.any?(failed.payload.activity, &(&1.kind == "output" and &1.summary == "partial assistant output"))
  end

  test "turn.failed still becomes a writer-owned agent failure when codex exits non-zero", ctx do
    id = run_id()
    detail = %{"message" => "codex backend exploded"}

    assert {:error, {:provider_failure, [0], :backend, ^detail}} =
             Run.run(EchoWorkflow.tree(), run_id: id, provider: codex(ctx, "turn_failed_exit"))

    assert settled_types(id) == [:run_started, :agent_failed]
    refute Enum.any?(Journal.fold(id), &(&1.type == :run_failed))
  end

  test "a terminal response is committed before a later idle app-server exit", ctx do
    id = run_id()

    assert {:ok, ^id} = Run.run(EchoWorkflow.tree(), run_id: id, provider: codex(ctx, "completed_exit"))
    assert settled_types(id) == [:run_started, :agent_committed, :run_completed]
  end

  test "stream-level error prevents successful settlement even after assistant output", ctx do
    id = run_id()
    detail = %{"message" => "codex stream failed"}

    assert {:error, {:provider_failure, [0], :backend, ^detail}} =
             Run.run(EchoWorkflow.tree(), run_id: id, provider: codex(ctx, "stream_error"))

    assert settled_types(id) == [:run_started, :agent_failed]
    refute Enum.any?(Journal.fold(id), &(&1.type == :agent_committed))
  end

  test "non-retrying app-server errors fail closed while retrying errors await terminal status", ctx do
    key = %Workflow.IdempotencyKey{run_id: "app-server-error", node_path: [0], iteration: 0}

    assert {:error, {:provider_failure, :backend, %{"message" => "transient backend error"}, %Usage{}, _activity}} =
             Codex.run_agent("ignored", nil, key, elem(codex(ctx, "error_nonretry"), 1))

    AppServer.reset()

    assert {:ok, "kept going", %Usage{}, _activity} =
             Codex.run_agent("kept going", nil, key, elem(codex(ctx, "error_retry"), 1))
  end

  test "turn timeout is an expected provider failure and interrupts only that turn", ctx do
    id = run_id()
    key = %Workflow.IdempotencyKey{run_id: id, node_path: [0], iteration: 0}
    {Codex, opts} = codex(ctx, "timeout")
    opts = Keyword.put(opts, :timeout, 100)
    detail = %{"message" => "codex turn timed out"}

    assert {:error, {:provider_failure, :timeout, ^detail, nil, direct_activity}} =
             Codex.run_agent("say hello", nil, key, opts)

    assert Enum.map(direct_activity, & &1.label) == ["Thread started", "Turn started"]

    assert {:error, {:provider_failure, [0], :timeout, ^detail}} =
             Run.run(EchoWorkflow.tree(), run_id: id, provider: {Codex, opts})

    assert settled_types(id) == [:run_started, :agent_failed]

    failed = Enum.find(Journal.fold(id), &(&1.type == :agent_failed))
    assert failed.payload.reason == {:provider_failure, :timeout, detail}
    assert failed.payload.usage == nil
    assert Enum.map(failed.payload.activity, & &1.label) == ["Thread started", "Turn started"]

    status = Status.of(id)
    assert status.state == :failed
    assert status.failure.reason == {:provider_failure, :timeout, detail}
    assert status.usage.total_tokens == 0

    assert [agent] = status.agents
    assert agent.status == :failed
    assert agent.usage == %Usage{}
    assert Enum.map(agent.activity, & &1.label) == ["Thread started", "Turn started"]
    assert agent.provider_failure == %ProviderFailure{kind: :timeout, detail: detail}
  end

  test "a schema-backed turn against the real provider honours fail-closed retry", ctx do
    id = run_id()
    counter = tmp("retry")
    on_exit(fn -> File.rm(counter) end)

    # The stub rejects the first invocation and corrects on the retry; the writer
    # re-runs the paid turn across the real boundary, so the retry gets fresh output.
    assert {:ok, ^id} =
             Run.run(SchemaWorkflow.tree(), run_id: id, provider: codex(ctx, "retry", [counter]))

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

  test "schema-backed turns use outputSchema without prompt schema-shape boilerplate", ctx do
    id = run_id()

    assert {:ok, ^id} =
             Run.run(SemanticSchemaWorkflow.tree(),
               run_id: id,
               provider: codex(ctx, "schema_prompt_contract")
             )

    committed = Enum.find(Journal.fold(id), &(&1.type == :agent_committed))

    assert committed.payload.result == %{
             "prompt" => "Findings must cite a concrete file and line.",
             "hasSchemaFile" => true
           }

    refute committed.payload.prompt =~ "Return only JSON"
    refute committed.payload.prompt =~ "matching the schema"
  end

  test "schema-backed assistant-output activity is a bounded preview while result stays complete", ctx do
    schema = %{
      "type" => "object",
      "properties" => %{"body" => %{"type" => "string"}},
      "required" => ["body"]
    }

    key = %Workflow.IdempotencyKey{run_id: "large_schema", node_path: [0], iteration: 0}

    assert {:ok, %{"body" => body}, %Usage{}, activity} =
             Codex.run_agent(
               "write a long schema output",
               schema,
               key,
               elem(codex(ctx, "large_schema_output"), 1)
             )

    assert String.length(body) == 504
    assert String.ends_with?(body, "tail")

    output = Enum.find(activity, &(&1.kind == "output"))
    assert String.length(output.summary) <= 183
    refute String.ends_with?(output.summary, "tail")
  end

  test "a real turn that never validates fails closed after exhausting retries", ctx do
    id = run_id()

    assert {:error, {:malformed_output, [0], _reason}} =
             Run.run(SchemaWorkflow.tree(), run_id: id, provider: codex(ctx, "always_invalid"))

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
    # Sanity: the compiled inert tree carries the normalized schema unchanged, and the
    # provider forwards it as inline `outputSchema` — the writer, not the provider,
    # decides validity.
    assert [%Workflow.Node.Agent{schema: schema} | _] = SchemaWorkflow.tree().nodes
    assert Schema.to_map(schema) == @bugs_schema
  end

  test "schemas handed to outputSchema are strict object schemas", ctx do
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

    assert {:ok, written, %Usage{}, _activity} =
             Codex.run_agent(
               "show schema",
               schema,
               key,
               elem(codex(ctx, "schema_file"), 1)
             )

    assert written["additionalProperties"] == false
    assert written["properties"]["items"]["items"]["additionalProperties"] == false
  end

  test "one app-server process is reused for sequential turns", ctx do
    starts = tmp("server_starts")
    on_exit(fn -> File.rm(starts) end)
    {Codex, opts} = codex(ctx, "server_count", [starts])

    for {prompt, iteration} <- [{"first", 0}, {"second", 1}] do
      key = %Workflow.IdempotencyKey{run_id: "reuse", node_path: [0], iteration: iteration}
      assert {:ok, ^prompt, %Usage{}, _activity} = Codex.run_agent(prompt, nil, key, opts)
    end

    assert File.read!(starts) == "started\n"
  end

  test "released-thread retention recycles the Port at a hard boundary", ctx do
    previous = Application.get_env(:codex_loops, :codex_app_server_max_released_threads)
    starts = tmp("released_thread_recycles")
    Application.put_env(:codex_loops, :codex_app_server_max_released_threads, 2)
    AppServer.reset()

    on_exit(fn ->
      restore_env(:codex_app_server_max_released_threads, previous)
      File.rm(starts)
      AppServer.reset()
    end)

    {Codex, opts} = codex(ctx, "server_count", [starts])

    for iteration <- 1..3 do
      prompt = "release-#{iteration}"
      key = %Workflow.IdempotencyKey{run_id: prompt, node_path: [0], iteration: 0}
      assert {:ok, ^prompt, %Usage{}, _activity} = Codex.run_agent(prompt, nil, key, opts)
    end

    wait_for_clean_app_server()
    assert wait_for_file_lines(starts, 2) == ["started", "started"]
    assert :sys.get_state(AppServer).released_threads == 1
  end

  test "completed and failed turns release their app-server thread subscriptions", ctx do
    unsubscribes = tmp("thread_unsubscribes")
    on_exit(fn -> File.rm(unsubscribes) end)
    {Codex, opts} = codex(ctx, "unsubscribe_capture", [unsubscribes])

    success_key = %Workflow.IdempotencyKey{run_id: "unsubscribe-success", node_path: [0], iteration: 0}
    failure_key = %Workflow.IdempotencyKey{run_id: "unsubscribe-failure", node_path: [0], iteration: 0}

    assert {:ok, "ok", %Usage{}, _activity} = Codex.run_agent("ok", nil, success_key, opts)

    assert {:error, {:provider_failure, :backend, %{"message" => "codex backend exploded"}, nil, _activity}} =
             Codex.run_agent("fail", nil, failure_key, opts)

    assert wait_for_file_lines(unsubscribes, 2) == ["t1", "t2"]
    wait_for_clean_app_server()
  end

  test "a request rejected after thread/start but before turn/start releases its subscription", ctx do
    previous = Application.get_env(:codex_loops, :codex_app_server_max_turn_bytes)
    unsubscribes = tmp("pre_turn_unsubscribes")
    Application.put_env(:codex_loops, :codex_app_server_max_turn_bytes, 1)
    AppServer.reset()

    on_exit(fn ->
      restore_env(:codex_app_server_max_turn_bytes, previous)
      File.rm(unsubscribes)
      AppServer.reset()
    end)

    key = %Workflow.IdempotencyKey{run_id: "pre-turn-release", node_path: [0], iteration: 0}
    {Codex, opts} = codex(ctx, "unsubscribe_capture", [unsubscribes])

    assert {:error, {:provider_failure, :backend, detail, nil, []}} =
             Codex.run_agent("turn/start must not be sent", nil, key, opts)

    assert detail["message"] == "Codex app-server turn notification limit exceeded"
    assert detail["maxBytes"] == 1
    assert wait_for_file_lines(unsubscribes, 1) == ["t1"]
    wait_for_clean_app_server()
  end

  test "an explicit cancellation after turn acceptance drains and unsubscribes", ctx do
    unsubscribes = tmp("cancel_unsubscribes")
    on_exit(fn -> File.rm(unsubscribes) end)

    request = %TurnRequest{
      prompt: "cancel me",
      cwd: File.cwd!(),
      thread_sandbox: "danger-full-access",
      turn_sandbox: %{"type" => "dangerFullAccess"},
      command: {ctx.python, [ctx.stub, "timeout_unsubscribe", unsubscribes, "app-server"]},
      timeout: 1_000
    }

    assert {:ok, ref, owner} = AppServer.start_turn(request)
    monitor = Process.monitor(owner)
    wait_for_turn_acceptance(ref, monitor)
    AppServer.cancel(ref)

    assert wait_for_file_lines(unsubscribes, 1) == ["t1"]
    wait_for_clean_app_server()
    Process.demonitor(monitor, [:flush])
  end

  test "a turn timeout after thread/start drains and unsubscribes", ctx do
    unsubscribes = tmp("timeout_unsubscribes")
    on_exit(fn -> File.rm(unsubscribes) end)
    key = %Workflow.IdempotencyKey{run_id: "timeout-unsubscribe", node_path: [0], iteration: 0}
    opts = ctx |> codex("timeout_unsubscribe", [unsubscribes]) |> elem(1) |> Keyword.put(:timeout, 75)

    assert {:error, {:provider_failure, :timeout, _detail, nil, _activity}} =
             Codex.run_agent("time out", nil, key, opts)

    assert wait_for_file_lines(unsubscribes, 1) == ["t1"]
    wait_for_clean_app_server()
  end

  test "unsubscribe errors and timeouts retire only after unrelated live turns settle", ctx do
    previous_active = Application.get_env(:codex_loops, :codex_app_server_max_active)
    previous_unsubscribe = Application.get_env(:codex_loops, :codex_app_server_unsubscribe_timeout)
    Application.put_env(:codex_loops, :codex_app_server_max_active, 2)
    Application.put_env(:codex_loops, :codex_app_server_unsubscribe_timeout, 40)
    AppServer.reset()

    on_exit(fn ->
      restore_env(:codex_app_server_max_active, previous_active)
      restore_env(:codex_app_server_unsubscribe_timeout, previous_unsubscribe)
      AppServer.reset()
    end)

    for mode <- ["unsubscribe_error_concurrent", "unsubscribe_hang_concurrent"] do
      AppServer.reset()
      starts = tmp(mode)
      on_exit(fn -> File.rm(starts) end)
      {Codex, base_opts} = codex(ctx, mode, [starts])
      opts = Keyword.put(base_opts, :timeout, 1_000)

      slow_key = %Workflow.IdempotencyKey{run_id: "#{mode}-slow", node_path: [0], iteration: 0}
      fast_key = %Workflow.IdempotencyKey{run_id: "#{mode}-fast", node_path: [0], iteration: 0}
      after_key = %Workflow.IdempotencyKey{run_id: "#{mode}-after", node_path: [0], iteration: 0}

      slow = Task.async(fn -> Codex.run_agent("slow", nil, slow_key, opts) end)
      wait_for_active_codex_request()
      fast = Task.async(fn -> Codex.run_agent("fast", nil, fast_key, opts) end)

      assert {:ok, "fast", %Usage{}, _activity} = Task.await(fast, 1_000)
      wait_for_retiring_app_server()
      assert Enum.any?(:sys.get_state(AppServer).requests, fn {_ref, request} -> request.phase == :running end)
      assert {:ok, "slow", %Usage{}, _activity} = Task.await(slow, 1_000)
      wait_for_app_server_status(:stopped)

      assert {:ok, "after", %Usage{}, _activity} = Codex.run_agent("after", nil, after_key, opts)
      assert length(wait_for_file_lines(starts, 2)) >= 2
      wait_for_app_server_status(:stopped)

      state = :sys.get_state(AppServer)
      assert state.requests == %{}
      assert state.rpc == %{}
      assert state.releasing == %{}
      assert state.draining == MapSet.new()
      assert :queue.len(state.waiting) == 0
    end
  end

  test "thread release correlations stay bounded across repeated turns", ctx do
    starts = tmp("bounded_release_starts")
    on_exit(fn -> File.rm(starts) end)
    {Codex, opts} = codex(ctx, "server_count", [starts])

    for iteration <- 1..25 do
      key = %Workflow.IdempotencyKey{run_id: "release-#{iteration}", node_path: [0], iteration: 0}
      prompt = "turn-#{iteration}"
      assert {:ok, ^prompt, %Usage{}, _activity} = Codex.run_agent(prompt, nil, key, opts)
    end

    wait_for_clean_app_server()
    state = :sys.get_state(AppServer)
    assert state.requests == %{}
    assert state.rpc == %{}
    assert state.releasing == %{}
    assert state.draining == MapSet.new()
    assert File.read!(starts) == "started\n"
  end

  test "cwd, model, approval, sandbox, and schema are sent as per-turn protocol fields", ctx do
    capture = tmp("protocol_capture")
    on_exit(fn -> File.rm(capture) end)
    {Codex, opts} = codex(ctx, "capture", [capture])
    opts = Keyword.merge(opts, workspace_root: "/tmp/codex-loops-workspace", model: "gpt-test")
    key = %Workflow.IdempotencyKey{run_id: "capture", node_path: [0], iteration: 0}
    schema = %{"type" => "object", "properties" => %{}, "required" => []}

    assert {:ok, %{}, %Usage{}, _activity} = Codex.run_agent("{}", schema, key, opts)

    messages =
      capture
      |> File.stream!()
      |> Enum.map(&JSON.decode!/1)

    thread = Enum.find(messages, &(&1["method"] == "thread/start"))["params"]
    turn = Enum.find(messages, &(&1["method"] == "turn/start"))["params"]

    assert thread["cwd"] == "/tmp/codex-loops-workspace"
    assert thread["model"] == "gpt-test"
    assert thread["approvalPolicy"] == "never"
    assert thread["sandbox"] == "danger-full-access"
    assert thread["ephemeral"] == true
    assert turn["cwd"] == "/tmp/codex-loops-workspace"
    assert turn["model"] == "gpt-test"
    assert turn["approvalPolicy"] == "never"
    assert turn["sandboxPolicy"] == %{"type" => "dangerFullAccess"}
    assert turn["outputSchema"]["additionalProperties"] == false
  end

  test "sandbox execution overrides cwd with an ephemeral workspace-write turn", ctx do
    capture = tmp("sandbox_capture")
    workdir = tmp("sandbox_workdir")
    previous = Application.get_env(:codex_loops, :codex_execution)
    Application.put_env(:codex_loops, :codex_execution, {:sandboxed, workdir})
    AppServer.reset()

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:codex_loops, :codex_execution)
      else
        Application.put_env(:codex_loops, :codex_execution, previous)
      end

      File.rm(capture)
      AppServer.reset()
    end)

    key = %Workflow.IdempotencyKey{run_id: "sandbox", node_path: [0], iteration: 0}
    opts = elem(codex(ctx, "capture", [capture]), 1)
    assert {:ok, "prompt", %Usage{}, _activity} = Codex.run_agent("prompt", nil, key, opts)

    messages = capture |> File.stream!() |> Enum.map(&JSON.decode!/1)
    thread = Enum.find(messages, &(&1["method"] == "thread/start"))["params"]
    turn = Enum.find(messages, &(&1["method"] == "turn/start"))["params"]

    assert thread["cwd"] == Path.expand(workdir)
    assert thread["sandbox"] == "workspace-write"
    assert thread["ephemeral"] == true
    assert turn["cwd"] == Path.expand(workdir)
    assert turn["sandboxPolicy"]["type"] == "workspaceWrite"
    assert turn["sandboxPolicy"]["writableRoots"] == [Path.expand(workdir)]
  end

  test "concurrent turns are correlated to their own caller", ctx do
    {Codex, opts} = codex(ctx, "concurrent")

    results =
      1..12
      |> Enum.map(fn iteration ->
        Task.async(fn ->
          prompt = "prompt-#{iteration}"
          key = %Workflow.IdempotencyKey{run_id: "concurrent", node_path: [iteration], iteration: 0}
          {prompt, Codex.run_agent(prompt, nil, key, opts)}
        end)
      end)
      |> Task.await_many(5_000)

    assert Enum.all?(results, fn {prompt, result} -> match?({:ok, ^prompt, %Usage{}, _activity}, result) end)
  end

  test "commentary messages remain activity but cannot replace the final answer", ctx do
    key = %Workflow.IdempotencyKey{run_id: "phases", node_path: [0], iteration: 0}

    assert {:ok, "final", %Usage{}, activity} =
             Codex.run_agent("ignored", nil, key, elem(codex(ctx, "commentary_then_final"), 1))

    assert activity |> Enum.filter(&(&1.kind == "output")) |> Enum.map(& &1.summary) == ["interim", "final"]
  end

  test "interactive approval requests fail closed without hanging", ctx do
    key = %Workflow.IdempotencyKey{run_id: "approval", node_path: [0], iteration: 0}
    opts = ctx |> codex("approval") |> elem(1) |> Keyword.put(:timeout, 1_000)

    assert {:error, {:provider_failure, :backend, detail, nil, activity}} =
             Codex.run_agent("do not prompt", nil, key, opts)

    assert detail == %{
             "message" => "Codex requested unsupported interactive input",
             "method" => "item/commandExecution/requestApproval"
           }

    assert Enum.map(activity, & &1.label) == ["Thread started", "Turn started"]
  end

  test "a turn-start timeout delivers one terminal even if the transport then fails", ctx do
    request = %TurnRequest{
      prompt: "timeout while turn/start is pending",
      cwd: File.cwd!(),
      thread_sandbox: "danger-full-access",
      turn_sandbox: %{"type" => "dangerFullAccess"},
      command: {ctx.python, [ctx.stub, "turn_start_hang", "app-server"]},
      timeout: 1_000
    }

    assert {:ok, ref, owner} = AppServer.start_turn(request)
    monitor = Process.monitor(owner)
    wait_for_request_phase(ref, :turn_starting)

    assert {:error, :timeout, %{"message" => "codex turn timed out"}} =
             wait_for_terminal(ref, monitor)

    wait_for_request_phase(ref, :cancelling_start)
    assert :ok = AppServer.reset()
    assert :timeout = AppServer.next_event(ref, monitor, 100)
    Process.demonitor(monitor, [:flush])
  end

  test "an interactive request before the turn-start response is drained and released once", ctx do
    lifecycle = tmp("approval_before_turn_response")
    on_exit(fn -> File.rm(lifecycle) end)

    request = %TurnRequest{
      prompt: "do not prompt",
      cwd: File.cwd!(),
      thread_sandbox: "danger-full-access",
      turn_sandbox: %{"type" => "dangerFullAccess"},
      command: {ctx.python, [ctx.stub, "approval_before_turn_response", lifecycle, "app-server"]},
      timeout: 1_000
    }

    assert {:ok, ref, owner} = AppServer.start_turn(request)
    monitor = Process.monitor(owner)

    assert {:error, :backend,
            %{
              "message" => "Codex requested unsupported interactive input",
              "method" => "item/commandExecution/requestApproval"
            }} = wait_for_terminal(ref, monitor)

    assert wait_for_file_lines(lifecycle, 2) == ["interrupt", "unsubscribe"]
    wait_for_clean_app_server()
    assert :timeout = AppServer.next_event(ref, monitor, 100)
    Process.demonitor(monitor, [:flush])
  end

  test "a port crash after turn acceptance leaves the paid attempt outcome unknown", ctx do
    id = run_id()

    assert {:error, {:run_crashed, {:codex_turn_outcome_unknown, detail}}} =
             Run.run(EchoWorkflow.tree(), run_id: id, provider: codex(ctx, "crash_after_accept"))

    assert detail["message"] =~ "app-server"
    events = Journal.fold(id)
    assert Enum.any?(events, &(&1.type == :agent_started))
    refute Enum.any?(events, &(&1.type in [:agent_failed, :agent_committed]))

    assert %Status{failure: %{reason: {:outcome_unknown, %Workflow.IdempotencyKey{run_id: ^id}}}} = Status.of(id)

    assert {:error, {:outcome_unknown, %{address: [0], iteration: 0, attempt: 0}}} =
             Run.run(EchoWorkflow.tree(), run_id: id, provider: codex(ctx, "echo"))
  end

  test "malformed and oversized protocol lines are bounded ambiguous failures after acceptance", ctx do
    for mode <- ["malformed", "oversize"] do
      AppServer.reset()
      key = %Workflow.IdempotencyKey{run_id: mode, node_path: [0], iteration: 0}
      opts = elem(codex(ctx, mode), 1)
      parent = self()

      {pid, monitor} =
        spawn_monitor(fn ->
          send(parent, {:unexpected_provider_result, Codex.run_agent("prompt", nil, key, opts)})
        end)

      assert_receive {:DOWN, ^monitor, :process, ^pid, {:codex_turn_outcome_unknown, detail}}, 2_000
      assert detail["message"] =~ "Codex app-server emitted"
      refute_receive {:unexpected_provider_result, _result}
    end
  end

  test "an app-server that never initializes is torn down at a bounded deadline", ctx do
    previous = Application.get_env(:codex_loops, :codex_app_server_initialize_timeout)
    Application.put_env(:codex_loops, :codex_app_server_initialize_timeout, 50)
    AppServer.reset()

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:codex_loops, :codex_app_server_initialize_timeout)
      else
        Application.put_env(:codex_loops, :codex_app_server_initialize_timeout, previous)
      end

      AppServer.reset()
    end)

    key = %Workflow.IdempotencyKey{run_id: "init-timeout", node_path: [0], iteration: 0}
    opts = ctx |> codex("initialize_hang") |> elem(1) |> Keyword.put(:timeout, 1_000)

    assert {:error, {:provider_failure, :unavailable, detail, nil, []}} =
             Codex.run_agent("prompt", nil, key, opts)

    assert detail["message"] == "Codex app-server initialize timed out"
  end

  test "aggregate per-turn notification volume is bounded across valid lines", ctx do
    previous = Application.get_env(:codex_loops, :codex_app_server_max_turn_events)
    Application.put_env(:codex_loops, :codex_app_server_max_turn_events, 5)
    AppServer.reset()

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:codex_loops, :codex_app_server_max_turn_events)
      else
        Application.put_env(:codex_loops, :codex_app_server_max_turn_events, previous)
      end

      AppServer.reset()
    end)

    key = %Workflow.IdempotencyKey{run_id: "event-flood", node_path: [0], iteration: 0}

    assert {:error, {:provider_failure, :backend, detail, nil, activity}} =
             Codex.run_agent("prompt", nil, key, elem(codex(ctx, "event_flood"), 1))

    assert detail["message"] == "Codex app-server turn notification limit exceeded"
    assert detail["maxEvents"] == 5
    assert length(activity) == 5
  end

  test "prompt bytes are bounded before admission to the app-server" do
    key = %Workflow.IdempotencyKey{run_id: "large-prompt", node_path: [0], iteration: 0}
    prompt = String.duplicate("x", 16 * 1_024 * 1_024 + 1)

    assert {:error, {:provider_failure, :model_limit, detail, nil, []}} =
             Codex.run_agent(prompt, nil, key, [])

    assert detail["message"] == "codex prompt exceeded the provider input limit"
    assert detail["maxBytes"] == 16 * 1_024 * 1_024
  end

  test "a bounded admission timeout cancels its late mailbox request without retrying", ctx do
    previous = Application.get_env(:codex_loops, :codex_app_server_admission_timeout)
    Application.put_env(:codex_loops, :codex_app_server_admission_timeout, 25)

    on_exit(fn ->
      restore_env(:codex_app_server_admission_timeout, previous)
      AppServer.reset()
    end)

    key = %Workflow.IdempotencyKey{run_id: "admission-timeout", node_path: [0], iteration: 0}
    :ok = :sys.suspend(AppServer)

    reason =
      try do
        catch_exit(
          Codex.run_agent(
            "prompt",
            nil,
            key,
            elem(codex(ctx, "echo"), 1)
          )
        )
      after
        :ok = :sys.resume(AppServer)
      end

    assert {:codex_turn_outcome_unknown, detail} = reason
    assert detail["message"] == "Codex app-server admission timed out"
    assert detail["timeoutMs"] == 25
    wait_for_no_codex_requests()
  end

  test "configured admission and JSON line limits cannot exceed their hard bounds" do
    previous_pending = Application.get_env(:codex_loops, :codex_app_server_max_pending)
    previous_line = Application.get_env(:codex_loops, :codex_app_server_max_line_bytes)
    previous_released = Application.get_env(:codex_loops, :codex_app_server_max_released_threads)
    Application.put_env(:codex_loops, :codex_app_server_max_pending, 1_000_000)
    Application.put_env(:codex_loops, :codex_app_server_max_line_bytes, 16_000_000)
    Application.put_env(:codex_loops, :codex_app_server_max_released_threads, 1_000_000)

    on_exit(fn ->
      restore_env(:codex_app_server_max_pending, previous_pending)
      restore_env(:codex_app_server_max_line_bytes, previous_line)
      restore_env(:codex_app_server_max_released_threads, previous_released)
      AppServer.reset()
    end)

    AppServer.reset()
    state = :sys.get_state(AppServer)

    assert state.max_pending == 64
    assert state.max_line_bytes == 1_048_576
    assert state.max_released_threads == 64
  end

  test "an interrupt that never completes recycles the transport before admitting more work", ctx do
    previous_active = Application.get_env(:codex_loops, :codex_app_server_max_active)
    previous_interrupt = Application.get_env(:codex_loops, :codex_app_server_interrupt_timeout)
    Application.put_env(:codex_loops, :codex_app_server_max_active, 1)
    Application.put_env(:codex_loops, :codex_app_server_interrupt_timeout, 50)
    AppServer.reset()

    on_exit(fn ->
      restore_env(:codex_app_server_max_active, previous_active)
      restore_env(:codex_app_server_interrupt_timeout, previous_interrupt)
      AppServer.reset()
    end)

    {Codex, base_opts} = codex(ctx, "ignore_interrupt")
    first_key = %Workflow.IdempotencyKey{run_id: "ignored-interrupt-1", node_path: [0], iteration: 0}
    second_key = %Workflow.IdempotencyKey{run_id: "ignored-interrupt-2", node_path: [0], iteration: 0}

    first = Task.async(fn -> Codex.run_agent("first", nil, first_key, Keyword.put(base_opts, :timeout, 300)) end)
    wait_for_running_codex_request()
    second = Task.async(fn -> Codex.run_agent("second", nil, second_key, Keyword.put(base_opts, :timeout, 1_000)) end)

    assert {:error, {:provider_failure, :timeout, _detail, nil, _activity}} = Task.await(first, 1_000)

    assert {:error, {:provider_failure, :backend, detail, nil, []}} = Task.await(second, 1_000)
    assert detail["message"] == "Codex app-server did not complete an interrupted turn"

    echo_key = %Workflow.IdempotencyKey{run_id: "after-recycle", node_path: [0], iteration: 0}

    assert {:ok, "after", %Usage{}, _activity} =
             Codex.run_agent("after", nil, echo_key, elem(codex(ctx, "echo"), 1))
  end

  test "queued caller churn removes queue entries instead of retaining tombstones", ctx do
    previous_active = Application.get_env(:codex_loops, :codex_app_server_max_active)
    previous_pending = Application.get_env(:codex_loops, :codex_app_server_max_pending)
    Application.put_env(:codex_loops, :codex_app_server_max_active, 1)
    Application.put_env(:codex_loops, :codex_app_server_max_pending, 1)
    AppServer.reset()

    on_exit(fn ->
      restore_env(:codex_app_server_max_active, previous_active)
      restore_env(:codex_app_server_max_pending, previous_pending)
      AppServer.reset()
    end)

    {Codex, base_opts} = codex(ctx, "timeout")
    active_key = %Workflow.IdempotencyKey{run_id: "queue-active", node_path: [0], iteration: 0}
    active = Task.async(fn -> Codex.run_agent("active", nil, active_key, Keyword.put(base_opts, :timeout, 500)) end)
    wait_for_active_codex_request()

    for iteration <- 1..12 do
      key = %Workflow.IdempotencyKey{run_id: "queue-#{iteration}", node_path: [0], iteration: 0}

      assert {:error, {:provider_failure, :timeout, _detail, nil, []}} =
               Codex.run_agent("queued", nil, key, Keyword.put(base_opts, :timeout, 10))
    end

    state = :sys.get_state(AppServer)
    assert :queue.len(state.waiting) == 0
    assert map_size(state.requests) == 1
    assert {:error, {:provider_failure, :timeout, _detail, nil, _activity}} = Task.await(active, 1_000)
  end

  test "cancellation during thread/start safely recycles before admitting queued work", ctx do
    previous_active = Application.get_env(:codex_loops, :codex_app_server_max_active)
    Application.put_env(:codex_loops, :codex_app_server_max_active, 1)
    AppServer.reset()
    starts = tmp("thread_start_recycles")

    on_exit(fn ->
      restore_env(:codex_app_server_max_active, previous_active)
      File.rm(starts)
      AppServer.reset()
    end)

    request = %TurnRequest{
      prompt: "prompt",
      cwd: File.cwd!(),
      thread_sandbox: "danger-full-access",
      turn_sandbox: %{"type" => "dangerFullAccess"},
      command: {ctx.python, [ctx.stub, "thread_hang", starts, "app-server"]},
      timeout: 1_000
    }

    assert {:ok, first_ref, _owner} = AppServer.start_turn(request)
    assert {:ok, second_ref, _owner} = AppServer.start_turn(request)
    wait_for_request_phase(first_ref, :thread_start)
    wait_for_request_phase(second_ref, :queued)
    first_port = :sys.get_state(AppServer).port

    AppServer.cancel(first_ref)

    wait_for_request_phase(second_ref, :thread_start)
    second_port = :sys.get_state(AppServer).port
    refute first_port == second_port
    assert length(wait_for_file_lines(starts, 2)) >= 2
  end

  defp restore_env(key, nil), do: Application.delete_env(:codex_loops, key)
  defp restore_env(key, value), do: Application.put_env(:codex_loops, key, value)

  defp wait_for_active_codex_request(attempts \\ 100)

  defp wait_for_active_codex_request(0), do: flunk("Codex request never became active")

  defp wait_for_active_codex_request(attempts) do
    state = :sys.get_state(AppServer)

    if Enum.any?(state.requests, fn {_ref, request} -> request.phase != :queued end) do
      :ok
    else
      Process.sleep(5)
      wait_for_active_codex_request(attempts - 1)
    end
  end

  defp wait_for_running_codex_request(attempts \\ 200)

  defp wait_for_running_codex_request(0), do: flunk("Codex request never started running")

  defp wait_for_running_codex_request(attempts) do
    if Enum.any?(:sys.get_state(AppServer).requests, fn {_ref, request} -> request.phase == :running end) do
      :ok
    else
      Process.sleep(5)
      wait_for_running_codex_request(attempts - 1)
    end
  end

  defp wait_for_request_phase(ref, phase, attempts \\ 100)

  defp wait_for_request_phase(_ref, phase, 0), do: flunk("Codex request never reached #{phase}")

  defp wait_for_request_phase(ref, phase, attempts) do
    case :sys.get_state(AppServer).requests do
      %{^ref => %{phase: ^phase}} ->
        :ok

      _other ->
        Process.sleep(5)
        wait_for_request_phase(ref, phase, attempts - 1)
    end
  end

  defp wait_for_no_codex_requests(attempts \\ 100)

  defp wait_for_no_codex_requests(0), do: flunk("Codex admission request was not cancelled")

  defp wait_for_no_codex_requests(attempts) do
    if map_size(:sys.get_state(AppServer).requests) == 0 do
      :ok
    else
      Process.sleep(5)
      wait_for_no_codex_requests(attempts - 1)
    end
  end

  defp wait_for_turn_acceptance(ref, monitor, attempts \\ 100)

  defp wait_for_turn_acceptance(_ref, _monitor, 0), do: flunk("Codex turn was never accepted")

  defp wait_for_turn_acceptance(ref, monitor, attempts) do
    case AppServer.next_event(ref, monitor, 100) do
      :accepted -> :ok
      {:owner_down, reason} -> flunk("Codex app-server owner exited: #{inspect(reason)}")
      _event -> wait_for_turn_acceptance(ref, monitor, attempts - 1)
    end
  end

  defp wait_for_terminal(ref, monitor, attempts \\ 100)

  defp wait_for_terminal(_ref, _monitor, 0), do: flunk("Codex turn never delivered a terminal result")

  defp wait_for_terminal(ref, monitor, attempts) do
    case AppServer.next_event(ref, monitor, 100) do
      {:terminal, terminal} -> terminal
      {:owner_down, reason} -> flunk("Codex app-server owner exited: #{inspect(reason)}")
      _event -> wait_for_terminal(ref, monitor, attempts - 1)
    end
  end

  defp wait_for_file_lines(path, count, attempts \\ 200)

  defp wait_for_file_lines(path, _count, 0), do: flunk("Timed out waiting for #{path}")

  defp wait_for_file_lines(path, count, attempts) do
    lines =
      case File.read(path) do
        {:ok, contents} -> String.split(contents, "\n", trim: true)
        {:error, :enoent} -> []
      end

    if length(lines) >= count do
      lines
    else
      Process.sleep(5)
      wait_for_file_lines(path, count, attempts - 1)
    end
  end

  defp wait_for_clean_app_server(attempts \\ 200)

  defp wait_for_clean_app_server(0), do: flunk("Codex app-server retained completed request state")

  defp wait_for_clean_app_server(attempts) do
    state = :sys.get_state(AppServer)

    if state.requests == %{} and state.rpc == %{} and state.releasing == %{} and state.draining == MapSet.new() do
      :ok
    else
      Process.sleep(5)
      wait_for_clean_app_server(attempts - 1)
    end
  end

  defp wait_for_retiring_app_server(attempts \\ 200)

  defp wait_for_retiring_app_server(0), do: flunk("Codex app-server never entered retirement")

  defp wait_for_retiring_app_server(attempts) do
    if :sys.get_state(AppServer).retiring do
      :ok
    else
      Process.sleep(5)
      wait_for_retiring_app_server(attempts - 1)
    end
  end

  defp wait_for_app_server_status(status, attempts \\ 200)

  defp wait_for_app_server_status(status, 0), do: flunk("Codex app-server never reached #{status}")

  defp wait_for_app_server_status(status, attempts) do
    if :sys.get_state(AppServer).port_status == status do
      :ok
    else
      Process.sleep(5)
      wait_for_app_server_status(status, attempts - 1)
    end
  end
end
