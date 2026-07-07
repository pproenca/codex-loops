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
    respond_result(id, %{"tools" => [workflow_validate_tool()]})
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
    with {:ok, state} <- Lifecycle.ensure_ready(state) do
      case SchedulerClient.validate_workflow(script_path) do
        {:ok, envelope} ->
          {:ok, tool_result(envelope, false), state}

        {:scheduler_error, envelope} ->
          {:ok, tool_result(envelope, true), state}

        {:unexpected, status, payload} ->
          envelope =
            error_envelope(
              "scheduler_unexpected_response",
              "Scheduler returned an unexpected response.",
              %{
                http_status: status,
                payload: payload
              }
            )

          {:ok, tool_result(envelope, true), state}

        {:error, reason} ->
          envelope =
            error_envelope("scheduler_unavailable", "Scheduler could not be reached.", %{
              scheduler_url: SchedulerClient.config().base_url,
              reason: reason
            })

          {:ok, tool_result(envelope, true), state}
      end
    else
      {:error, envelope, state} ->
        {:ok, tool_result(envelope, true), state}
    end
  end

  defp call_tool(%{"name" => "workflow_validate", "arguments" => arguments}, state) do
    {:error, -32602, "Invalid params",
     %{
       "reason" => "workflow_validate requires arguments.script_path as a string",
       "arguments" => arguments
     }, state}
  end

  defp call_tool(%{"name" => "workflow_validate"}, state) do
    {:error, -32602, "Invalid params",
     %{"reason" => "workflow_validate requires arguments.script_path as a string"}, state}
  end

  defp call_tool(%{"name" => name}, state) when is_binary(name) do
    {:error, -32602, "Invalid params", %{"reason" => "unknown tool", "tool" => name}, state}
  end

  defp call_tool(_params, state) do
    {:error, -32602, "Invalid params", %{"reason" => "tools/call requires a tool name"}, state}
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

  defp app_version do
    :codex_loops
    |> Application.spec(:vsn)
    |> to_string()
  rescue
    _error -> "0.0.0"
  end
end
