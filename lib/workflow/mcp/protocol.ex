defmodule Workflow.MCP.Protocol do
  @moduledoc """
  Stateless MCP JSON-RPC handling for the scheduler's Streamable HTTP endpoint.

  The endpoint advertises tools only and deliberately does not allocate MCP
  session processes or SSE streams. Protocol version `2025-03-26` retains its
  legacy JSON-RPC batch receive semantics; newer versions accept one message
  per POST.
  """

  alias Workflow.MCP.Tools
  alias Workflow.PackageVersion

  @supported_versions ~w[2025-03-26 2025-06-18 2025-11-25]
  @latest_version List.last(@supported_versions)
  @default_http_version "2025-03-26"

  @parse_error -32_700
  @invalid_request -32_600
  @method_not_found -32_601
  @invalid_params -32_602

  @type response :: map() | [map()]
  @type outcome :: {:reply, response()} | :accepted | {:bad_request, map()}

  @spec supported_versions() :: [String.t()]
  def supported_versions, do: @supported_versions

  @spec handle(term(), keyword()) :: outcome()
  def handle(message, opts \\ [])

  def handle(messages, opts) when is_list(messages) do
    case protocol_version(Keyword.get(opts, :protocol_version)) do
      {:ok, "2025-03-26"} ->
        handle_batch(messages, opts)

      {:ok, _newer_version} ->
        {:bad_request, invalid_request("JSON-RPC batches are not supported by this protocol version")}

      {:error, response} ->
        {:bad_request, response}
    end
  end

  def handle(message, opts) do
    if initialize_request?(message) do
      dispatch(message, opts)
    else
      case protocol_version(Keyword.get(opts, :protocol_version)) do
        {:ok, _version} -> dispatch(message, opts)
        {:error, response} -> {:bad_request, response}
      end
    end
  end

  @spec error_response(term(), integer(), String.t(), term()) :: map()
  def error_response(id, code, message, data \\ nil) do
    error = %{"code" => code, "message" => message}
    error = if is_nil(data), do: error, else: Map.put(error, "data", data)

    maybe_put_id(%{"jsonrpc" => "2.0", "error" => error}, id)
  end

  @spec parse_error() :: map()
  def parse_error, do: error_response(nil, @parse_error, "Parse error")

  @spec invalid_request(String.t()) :: map()
  def invalid_request(message \\ "Invalid Request"), do: error_response(nil, @invalid_request, message)

  defp handle_batch([], _opts), do: {:bad_request, invalid_request("JSON-RPC batch must not be empty")}

  defp handle_batch(messages, opts) do
    responses =
      Enum.flat_map(messages, fn message ->
        case dispatch_batch_item(message, opts) do
          {:reply, response} -> [response]
          {:bad_request, response} -> [response]
          :accepted -> []
        end
      end)

    case responses do
      [] -> :accepted
      responses -> {:reply, responses}
    end
  end

  defp dispatch_batch_item(%{"jsonrpc" => "2.0", "id" => id, "method" => "initialize"} = request, _opts)
       when is_binary(id) or is_integer(id) do
    {:reply,
     error_response(
       request_id(request),
       @invalid_request,
       "initialize must not be part of a JSON-RPC batch"
     )}
  end

  defp dispatch_batch_item(%{"jsonrpc" => "2.0", "method" => method} = notification, opts)
       when is_binary(method) and not is_map_key(notification, "id") do
    # JSON-RPC never emits a response for notification entries, even when the
    # notification itself has malformed params. Dispatch still classifies it so
    # adding side-effecting notifications later cannot accidentally skip work.
    _outcome = dispatch(notification, opts)
    :accepted
  end

  defp dispatch_batch_item(message, opts), do: dispatch(message, opts)

  defp dispatch(
         %{
           "jsonrpc" => "2.0",
           "id" => id,
           "method" => "initialize",
           "params" => %{
             "protocolVersion" => requested,
             "capabilities" => capabilities,
             "clientInfo" => %{"name" => client_name, "version" => client_version}
           }
         },
         _opts
       )
       when (is_binary(id) or is_integer(id)) and is_binary(requested) and is_map(capabilities) and is_binary(client_name) and
              is_binary(client_version) do
    selected = if requested in @supported_versions, do: requested, else: @latest_version

    {:reply,
     success(id, %{
       "protocolVersion" => selected,
       "capabilities" => %{"tools" => %{"listChanged" => false}},
       "serverInfo" => %{
         "name" => "codex-loops",
         "title" => "Codex Loops Scheduler",
         "version" => PackageVersion.version()
       },
       "instructions" =>
         "Validate, start, inspect, resume, and open Codex Loops workflows through the local scheduler. Relative script paths require an explicit absolute workspace_root."
     })}
  end

  defp dispatch(%{"jsonrpc" => "2.0", "id" => id, "method" => "initialize"}, _opts)
       when is_binary(id) or is_integer(id) do
    {:reply, error_response(id, @invalid_params, "Invalid initialize parameters")}
  end

  defp dispatch(%{"jsonrpc" => "2.0", "id" => id, "method" => "ping"} = request, _opts)
       when is_binary(id) or is_integer(id) do
    if valid_params?(request),
      do: {:reply, success(id, %{})},
      else: {:reply, error_response(id, @invalid_params, "ping params must be an object")}
  end

  defp dispatch(%{"jsonrpc" => "2.0", "id" => id, "method" => "tools/list"} = request, _opts)
       when is_binary(id) or is_integer(id) do
    if valid_params?(request),
      do: {:reply, success(id, %{"tools" => Tools.catalog()})},
      else: {:reply, error_response(id, @invalid_params, "tools/list params must be an object")}
  end

  defp dispatch(%{"jsonrpc" => "2.0", "id" => id, "method" => "tools/call", "params" => %{"name" => name} = params}, opts)
       when (is_binary(id) or is_integer(id)) and is_binary(name) do
    arguments = Map.get(params, "arguments", %{})

    case Tools.call(name, arguments, base_url: Keyword.get(opts, :base_url, "http://127.0.0.1:47125")) do
      {:ok, result} -> {:reply, success(id, result)}
      {:invalid_params, message} -> {:reply, error_response(id, @invalid_params, message)}
    end
  end

  defp dispatch(%{"jsonrpc" => "2.0", "id" => id, "method" => "tools/call"}, _opts)
       when is_binary(id) or is_integer(id) do
    {:reply, error_response(id, @invalid_params, "tools/call requires a tool name and object arguments")}
  end

  defp dispatch(%{"jsonrpc" => "2.0", "id" => id, "method" => method}, _opts)
       when (is_binary(id) or is_integer(id)) and is_binary(method) do
    {:reply, error_response(id, @method_not_found, "Method not found: #{method}")}
  end

  defp dispatch(%{"jsonrpc" => "2.0", "method" => method} = notification, _opts)
       when is_binary(method) and not is_map_key(notification, "id") do
    :accepted
  end

  defp dispatch(%{"jsonrpc" => "2.0", "id" => id} = response, _opts)
       when (is_binary(id) or is_integer(id)) and not is_map_key(response, "method") do
    if valid_client_response?(response),
      do: :accepted,
      else: {:bad_request, invalid_request()}
  end

  defp dispatch(%{} = request, _opts) do
    id = request_id(request)
    {:reply, error_response(id, @invalid_request, "Invalid Request")}
  end

  defp dispatch(_message, _opts), do: {:bad_request, invalid_request()}

  defp initialize_request?(%{"method" => "initialize"}), do: true
  defp initialize_request?(_message), do: false

  defp protocol_version(nil), do: {:ok, @default_http_version}

  defp protocol_version(version) when version in @supported_versions, do: {:ok, version}

  defp protocol_version(version) do
    {:error,
     error_response(nil, @invalid_request, "Unsupported MCP protocol version", %{
       "received" => version,
       "supported" => @supported_versions
     })}
  end

  defp valid_params?(request) do
    case Map.fetch(request, "params") do
      :error -> true
      {:ok, params} -> is_map(params)
    end
  end

  defp valid_client_response?(response) do
    case {Map.has_key?(response, "result"), Map.has_key?(response, "error")} do
      {true, false} -> true
      {false, true} -> valid_error?(response["error"])
      _both_or_neither -> false
    end
  end

  defp valid_error?(%{"code" => code, "message" => message}) when is_integer(code) and is_binary(message), do: true

  defp valid_error?(_error), do: false

  defp request_id(%{"id" => id}) when is_binary(id) or is_integer(id), do: id
  defp request_id(_request), do: nil

  defp success(id, result), do: %{"jsonrpc" => "2.0", "id" => id, "result" => result}

  defp maybe_put_id(response, nil), do: response
  defp maybe_put_id(response, id), do: Map.put(response, "id", id)
end
