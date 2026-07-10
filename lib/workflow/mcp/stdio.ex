defmodule Workflow.MCP.Stdio do
  @moduledoc """
  Newline-delimited JSON-RPC stdio adapter for Codex MCP clients.

  The adapter is intentionally thin: it owns client protocol handling and the
  optional scheduler OS process lifecycle, while workflow state stays behind the
  scheduler HTTP API.
  """

  alias Workflow.MCP.{Lifecycle, SchedulerClient}

  @protocol_version "2024-11-05"
  @api_version "codex-loops.mcp.v1"
  @start_argument_keys ["script_path", "run_id", "provider", "budget"]
  @resume_argument_keys ["script_path", "script", "provider"]

  @spec main([String.t()]) :: :ok | no_return()
  def main(args \\ System.argv()) do
    case args do
      [] ->
        run()

      ["--stdio"] ->
        run()

      ["--help"] ->
        IO.puts("Usage: codex-loops-mcp --stdio")

      _other ->
        IO.puts(:stderr, "Usage: codex-loops-mcp --stdio")
        System.halt(2)
    end
  end

  defp run do
    Lifecycle.new()
    |> loop()
    |> Lifecycle.stop_owned()

    :ok
  end

  defp loop(state) do
    state = Lifecycle.collect_port_messages(state)

    case IO.read(:stdio, :line) do
      :eof ->
        state

      {:error, reason} ->
        IO.puts(:stderr, "codex-loops MCP stdin error: #{inspect(reason)}")
        state

      line ->
        line
        |> String.trim()
        |> handle_line(state)
        |> case do
          {:cont, next_state} -> loop(next_state)
          {:stop, next_state} -> next_state
        end
    end
  end

  defp handle_line("", state), do: {:cont, state}

  defp handle_line(line, state) do
    case Jason.decode(line) do
      {:ok, %{} = message} ->
        handle_message(message, state)

      {:ok, _value} ->
        respond_error(nil, -32600, "Invalid Request", %{
          "reason" => "request must be a JSON object"
        })

        {:cont, state}

      {:error, error} ->
        respond_error(nil, -32700, "Parse error", %{"reason" => Exception.message(error)})
        {:cont, state}
    end
  end

  defp handle_message(%{"method" => method} = message, state) when is_binary(method) do
    if Map.has_key?(message, "id") do
      handle_request(method, Map.get(message, "params", %{}), message["id"], state)
    else
      handle_notification(method, state)
    end
  end

  defp handle_message(message, state) do
    id = Map.get(message, "id")
    respond_error(id, -32600, "Invalid Request", %{"reason" => "missing method"})
    {:cont, state}
  end

  defp handle_request("initialize", params, id, state) do
    requested_version =
      case params do
        %{"protocolVersion" => version} when is_binary(version) -> version
        _other -> @protocol_version
      end

    respond_result(id, %{
      "protocolVersion" => requested_version,
      "capabilities" => %{"tools" => %{}},
      "serverInfo" => %{
        "name" => "codex-loops",
        "version" => app_version()
      }
    })

    {:cont, state}
  end

  defp handle_request("ping", _params, id, state) do
    respond_result(id, %{})
    {:cont, state}
  end

  defp handle_request("tools/list", _params, id, state) do
    respond_result(id, %{"tools" => workflow_tools()})
    {:cont, state}
  end

  defp handle_request("tools/call", params, id, state) do
    case call_tool(params, state) do
      {:ok, result, next_state} ->
        respond_result(id, result)
        {:cont, next_state}

      {:error, code, message, data, next_state} ->
        respond_error(id, code, message, data)
        {:cont, next_state}
    end
  end

  defp handle_request("shutdown", _params, id, state) do
    respond_result(id, %{})
    {:stop, state}
  end

  defp handle_request(method, _params, id, state) do
    respond_error(id, -32601, "Method not found", %{"method" => method})
    {:cont, state}
  end

  defp handle_notification("notifications/initialized", state), do: {:cont, state}
  defp handle_notification("initialized", state), do: {:cont, state}
  defp handle_notification(_method, state), do: {:cont, state}

  defp call_tool(
         %{"name" => "workflow_validate", "arguments" => %{"script_path" => script_path}},
         state
       )
       when is_binary(script_path) do
    call_scheduler_tool(state, fn -> SchedulerClient.validate_workflow(script_path) end)
  end

  defp call_tool(%{"name" => "workflow_validate", "arguments" => arguments}, state) do
    invalid_tool_params(
      "workflow_validate requires arguments.script_path as a string",
      arguments,
      state
    )
  end

  defp call_tool(%{"name" => "workflow_validate"}, state) do
    invalid_tool_params(
      "workflow_validate requires arguments.script_path as a string",
      nil,
      state
    )
  end

  defp call_tool(%{"name" => "workflow_start", "arguments" => arguments}, state) do
    case workflow_start_arguments(arguments) do
      {:ok, attrs} ->
        call_scheduler_tool(state, fn -> SchedulerClient.start_run(attrs) end)

      {:error, reason} ->
        invalid_tool_params(reason, arguments, state)
    end
  end

  defp call_tool(%{"name" => "workflow_start"}, state) do
    invalid_tool_params("workflow_start requires arguments.script_path as a string", nil, state)
  end

  defp call_tool(%{"name" => "workflow_status", "arguments" => %{"run_id" => run_id}}, state)
       when is_binary(run_id) and byte_size(run_id) > 0 do
    call_scheduler_tool(state, fn -> SchedulerClient.get_run(run_id) end)
  end

  defp call_tool(%{"name" => "workflow_status", "arguments" => arguments}, state) do
    invalid_tool_params(
      "workflow_status requires arguments.run_id as a non-empty string",
      arguments,
      state
    )
  end

  defp call_tool(%{"name" => "workflow_status"}, state) do
    invalid_tool_params(
      "workflow_status requires arguments.run_id as a non-empty string",
      nil,
      state
    )
  end

  defp call_tool(%{"name" => "workflow_inspect", "arguments" => %{"run_id" => run_id}}, state)
       when is_binary(run_id) and byte_size(run_id) > 0 do
    call_scheduler_tool(state, fn -> SchedulerClient.get_run_events(run_id) end)
  end

  defp call_tool(%{"name" => "workflow_inspect", "arguments" => arguments}, state) do
    invalid_tool_params(
      "workflow_inspect requires arguments.run_id as a non-empty string",
      arguments,
      state
    )
  end

  defp call_tool(%{"name" => "workflow_inspect"}, state) do
    invalid_tool_params(
      "workflow_inspect requires arguments.run_id as a non-empty string",
      nil,
      state
    )
  end

  defp call_tool(%{"name" => "workflow_resume", "arguments" => arguments}, state) do
    case workflow_resume_arguments(arguments) do
      {:ok, run_id, attrs} ->
        call_scheduler_tool(state, fn -> SchedulerClient.resume_run(run_id, attrs) end)

      {:error, reason} ->
        invalid_tool_params(reason, arguments, state)
    end
  end

  defp call_tool(%{"name" => "workflow_resume"}, state) do
    invalid_tool_params(
      "workflow_resume requires arguments.run_id as a non-empty string",
      nil,
      state
    )
  end

  defp call_tool(%{"name" => "workflow_open_ui", "arguments" => %{"run_id" => run_id}}, state)
       when is_binary(run_id) and byte_size(run_id) > 0 do
    call_open_ui_tool(state, run_id)
  end

  defp call_tool(%{"name" => "workflow_open_ui", "arguments" => arguments}, state) do
    invalid_tool_params(
      "workflow_open_ui requires arguments.run_id as a non-empty string",
      arguments,
      state
    )
  end

  defp call_tool(%{"name" => "workflow_open_ui"}, state) do
    invalid_tool_params(
      "workflow_open_ui requires arguments.run_id as a non-empty string",
      nil,
      state
    )
  end

  defp call_tool(%{"name" => name}, state) when is_binary(name) do
    {:error, -32602, "Invalid params", %{"reason" => "unknown tool", "tool" => name}, state}
  end

  defp call_tool(_params, state) do
    {:error, -32602, "Invalid params", %{"reason" => "tools/call requires a tool name"}, state}
  end

  defp workflow_start_arguments(%{"script_path" => script_path} = arguments)
       when is_binary(script_path) do
    {:ok, Map.take(arguments, @start_argument_keys)}
  end

  defp workflow_start_arguments(_arguments) do
    {:error, "workflow_start requires arguments.script_path as a string"}
  end

  defp workflow_resume_arguments(%{"run_id" => run_id} = arguments)
       when is_binary(run_id) and byte_size(run_id) > 0 do
    {:ok, run_id, Map.take(arguments, @resume_argument_keys)}
  end

  defp workflow_resume_arguments(_arguments) do
    {:error, "workflow_resume requires arguments.run_id as a non-empty string"}
  end

  defp call_scheduler_tool(state, scheduler_fun) when is_function(scheduler_fun, 0) do
    with {:ok, state} <- Lifecycle.ensure_ready(state) do
      scheduler_fun.()
      |> scheduler_tool_response(state)
    else
      {:error, envelope, state} ->
        {:ok, tool_result(envelope, true), state}
    end
  end

  defp call_open_ui_tool(state, run_id) do
    with {:ok, state} <- Lifecycle.ensure_ready(state) do
      case SchedulerClient.get_run(run_id) do
        {:ok, %{"data" => %{} = projection}} ->
          {:ok, tool_result(open_ui_envelope(projection), false), state}

        {:ok, envelope} ->
          {:ok, tool_result(unexpected_response_envelope(200, envelope), true), state}

        other ->
          scheduler_tool_response(other, state)
      end
    else
      {:error, envelope, state} ->
        {:ok, tool_result(envelope, true), state}
    end
  end

  defp scheduler_tool_response({:ok, envelope}, state) do
    {:ok, tool_result(envelope, false), state}
  end

  defp scheduler_tool_response({:scheduler_error, envelope}, state) do
    {:ok, tool_result(envelope, true), state}
  end

  defp scheduler_tool_response({:unexpected, status, payload}, state) do
    {:ok, tool_result(unexpected_response_envelope(status, payload), true), state}
  end

  defp scheduler_tool_response({:error, reason}, state) do
    envelope =
      error_envelope("scheduler_unavailable", "Scheduler could not be reached.", %{
        scheduler_url: SchedulerClient.config().base_url,
        reason: reason
      })

    {:ok, tool_result(envelope, true), state}
  end

  defp invalid_tool_params(reason, nil, state) do
    {:error, -32602, "Invalid params", %{"reason" => reason}, state}
  end

  defp invalid_tool_params(reason, arguments, state) do
    {:error, -32602, "Invalid params", %{"reason" => reason, "arguments" => arguments}, state}
  end

  defp workflow_tools do
    [
      workflow_validate_tool(),
      workflow_start_tool(),
      workflow_status_tool(),
      workflow_inspect_tool(),
      workflow_resume_tool(),
      workflow_open_ui_tool()
    ]
  end

  defp workflow_validate_tool do
    %{
      "name" => "workflow_validate",
      "description" => "Validate a Codex Loops workflow script through the local scheduler API.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "script_path" => %{
            "type" => "string",
            "description" => "Path to the workflow .exs file to validate."
          }
        },
        "required" => ["script_path"],
        "additionalProperties" => false
      }
    }
  end

  defp workflow_start_tool do
    %{
      "name" => "workflow_start",
      "description" => "Start a Codex Loops workflow run through POST /api/runs.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "script_path" => %{
            "type" => "string",
            "description" => "Path to the workflow .exs file to run."
          },
          "run_id" => %{
            "type" => "string",
            "description" => "Optional route-safe run id to preserve across status and UI links."
          },
          "provider" => %{
            "type" => "string",
            "enum" => ["mock", "codex"],
            "description" =>
              "Optional scheduler provider. Defaults to mock; codex spends a real Codex turn."
          },
          "budget" => %{
            "type" => "integer",
            "minimum" => 0,
            "description" => "Optional non-negative scheduler budget."
          }
        },
        "required" => ["script_path"],
        "additionalProperties" => false
      }
    }
  end

  defp workflow_status_tool do
    %{
      "name" => "workflow_status",
      "description" =>
        "Read a scheduler run projection, including inspector-grade details, through GET /api/runs/:id.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "run_id" => %{
            "type" => "string",
            "description" => "Run id returned by workflow_start."
          }
        },
        "required" => ["run_id"],
        "additionalProperties" => false
      }
    }
  end

  defp workflow_inspect_tool do
    %{
      "name" => "workflow_inspect",
      "description" =>
        "Read ordered scheduler event projections and inspector-grade details through GET /api/runs/:id/events.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "run_id" => %{
            "type" => "string",
            "description" => "Run id returned by workflow_start or workflow_resume."
          }
        },
        "required" => ["run_id"],
        "additionalProperties" => false
      }
    }
  end

  defp workflow_resume_tool do
    %{
      "name" => "workflow_resume",
      "description" => "Resume an existing scheduler run through POST /api/runs/:id/resume.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "run_id" => %{
            "type" => "string",
            "description" => "Existing run id to resume."
          },
          "script_path" => %{
            "type" => "string",
            "description" =>
              "Optional workflow .exs path to use instead of the journaled script path."
          },
          "script" => %{
            "type" => "string",
            "description" => "Optional scheduler-supported alias for script_path."
          },
          "provider" => %{
            "type" => "string",
            "enum" => ["mock", "codex"],
            "description" =>
              "Optional scheduler provider. Defaults to mock; codex spends a real Codex turn."
          }
        },
        "required" => ["run_id"],
        "additionalProperties" => false
      }
    }
  end

  defp workflow_open_ui_tool do
    %{
      "name" => "workflow_open_ui",
      "description" => "Return the Phoenix LiveView URL for a scheduler run.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "run_id" => %{
            "type" => "string",
            "description" => "Run id returned by workflow_start."
          }
        },
        "required" => ["run_id"],
        "additionalProperties" => false
      }
    }
  end

  defp tool_result(envelope, is_error?) do
    %{
      "content" => [
        %{
          "type" => "text",
          "text" => Jason.encode!(envelope, pretty: true)
        }
      ],
      "structuredContent" => envelope,
      "isError" => is_error?
    }
  end

  defp respond_result(id, result) do
    write_message(%{"jsonrpc" => "2.0", "id" => id, "result" => result})
  end

  defp respond_error(id, code, message, data) do
    write_message(%{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => %{
        "code" => code,
        "message" => message,
        "data" => data
      }
    })
  end

  defp write_message(message) do
    IO.write(:stdio, Jason.encode!(message))
    IO.write(:stdio, "\n")
  end

  defp error_envelope(code, message, details) do
    %{
      "api_version" => @api_version,
      "error" => %{
        "code" => code,
        "message" => message,
        "details" => details
      }
    }
  end

  defp unexpected_response_envelope(status, payload) do
    error_envelope(
      "scheduler_unexpected_response",
      "Scheduler returned an unexpected response.",
      %{
        http_status: status,
        payload: payload
      }
    )
  end

  defp open_ui_envelope(projection) do
    ui_url = projection["ui_url"] || projection["ui_path"]

    %{
      "api_version" => @api_version,
      "data" => Map.put(projection, "open_url", absolute_open_url(ui_url))
    }
  end

  defp absolute_open_url(nil), do: SchedulerClient.config().base_url

  defp absolute_open_url(url) when is_binary(url) do
    uri = URI.parse(url)

    if uri.scheme && uri.host do
      url
    else
      SchedulerClient.config().base_url
      |> Kernel.<>("/")
      |> URI.merge(url)
      |> URI.to_string()
    end
  end

  defp app_version do
    :codex_loops
    |> Application.spec(:vsn)
    |> to_string()
  rescue
    _error -> "0.0.0"
  end
end
