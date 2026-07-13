defmodule Workflow.Install.MCP do
  @moduledoc false

  alias Workflow.Install.Change
  alias Workflow.Install.CodexBinding
  alias Workflow.Install.Command
  alias Workflow.Install.Error
  alias Workflow.PackageVersion

  @name "codex-loops"
  @url "http://127.0.0.1:47125/mcp"
  @probe_protocol_version "2025-03-26"
  @probe_id "codex-loops-install-probe"
  @server_keys ~w[auth_status disabled_reason disabled_tools enabled enabled_tools name startup_timeout_sec tool_timeout_sec transport]
  @http_transport_keys ~w[bearer_token_env_var env_http_headers http_headers type url]
  @stdio_transport_keys ~w[args command cwd env env_vars type]

  defmodule Registration do
    @moduledoc false
    @enforce_keys [:kind]
    defstruct [:kind, :url, :command, args: []]

    @type t :: %__MODULE__{
            kind: :http | :stdio,
            url: String.t() | nil,
            command: String.t() | nil,
            args: [String.t()]
          }
  end

  @type state :: :current | :missing | {:replace, Registration.t()}
  @type result(value) :: {:ok, value} | {:error, Error.t()}

  @spec name() :: String.t()
  def name, do: @name

  @spec url() :: String.t()
  def url, do: @url

  @spec inspect_state(CodexBinding.t(), keyword()) :: result(state())
  def inspect_state(%CodexBinding{} = binding, opts \\ []) do
    with :ok <- preflight(binding, opts),
         {:ok, servers} <- list(binding, opts) do
      servers
      |> Enum.find(&(&1["name"] == @name))
      |> classify()
    end
  end

  @spec install(CodexBinding.t(), state(), keyword()) :: result(Change.t())
  def install(%CodexBinding{} = binding, state, opts \\ []) do
    previous = previous_registration(state)

    with :ok <- verify_expected_state(binding, state, opts) do
      case replace_with_current(binding, previous, opts) do
        :ok ->
          case verify_current(binding, opts) do
            :ok ->
              rollback = fn -> restore(binding, previous, opts, :cas) end
              {:ok, Change.new("mcp", rollback)}

            {:error, %Error{} = error} ->
              rollback_failed_install(binding, previous, error, opts)
          end

        {:error, %Error{} = error} ->
          rollback_failed_install(binding, previous, error, opts)
      end
    end
  end

  @spec probe_endpoint(String.t(), keyword()) :: :ok | {:error, Error.t()}
  def probe_endpoint(base_url, opts \\ []) when is_binary(base_url) do
    case Keyword.get(opts, :mcp_endpoint_probe) do
      probe when is_function(probe, 1) -> normalize_probe_result(probe.(String.trim_trailing(base_url, "/") <> "/mcp"))
      nil -> request_initialize(base_url, opts)
    end
  end

  defp preflight(binding, opts) do
    case command(binding, ["mcp", "add", "--help"], opts, "mcp_preflight") do
      {:ok, output} ->
        if String.contains?(output, "--url") do
          :ok
        else
          {:error,
           Error.new(3, "codex_incompatible", "The selected Codex CLI does not support Streamable HTTP MCP registration.",
             details: %{"path" => binding.path}
           )}
        end

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp list(binding, opts) do
    with {:ok, output} <- command(binding, ["mcp", "list", "--json"], opts, "mcp_read"),
         {:ok, servers} when is_list(servers) <- Jason.decode(output),
         true <- valid_server_list?(servers),
         {:ok, servers} <- read_complete_target(binding, servers, opts) do
      {:ok, servers}
    else
      {:ok, _other} -> {:error, invalid_list()}
      {:error, %Jason.DecodeError{}} -> {:error, invalid_list()}
      {:error, %Error{} = error} -> {:error, error}
      false -> {:error, invalid_list()}
    end
  end

  defp valid_server_list?(servers) do
    Enum.all?(servers, &(is_map(&1) and is_binary(&1["name"]))) and
      Enum.count(servers, &(&1["name"] == @name)) <= 1
  end

  # `codex mcp list --json` intentionally omits tool filters, while
  # `codex mcp get NAME --json` includes them. Replacing from the list-only
  # shape could silently erase a user's enabled_tools/disabled_tools policy.
  defp read_complete_target(binding, servers, opts) do
    case Enum.find_index(servers, &(&1["name"] == @name)) do
      nil ->
        {:ok, servers}

      index ->
        with {:ok, output} <- command(binding, ["mcp", "get", @name, "--json"], opts, "mcp_read"),
             {:ok, server} when is_map(server) <- Jason.decode(output),
             true <- server["name"] == @name do
          {:ok, List.replace_at(servers, index, server)}
        else
          {:ok, _other} -> {:error, invalid_list()}
          {:error, %Jason.DecodeError{}} -> {:error, invalid_list()}
          {:error, %Error{} = error} -> {:error, error}
          false -> {:error, invalid_list()}
        end
    end
  end

  defp classify(nil), do: {:ok, :missing}

  defp classify(server) do
    if current?(server) do
      {:ok, :current}
    else
      case restorable(server) do
        {:ok, registration} -> {:ok, {:replace, registration}}
        :error -> {:error, non_restorable(server)}
      end
    end
  end

  defp current?(server) do
    known_fields?(server, @server_keys) and default_settings?(server) and
      match?(
        %{
          "type" => "streamable_http",
          "url" => @url,
          "bearer_token_env_var" => nil,
          "http_headers" => headers,
          "env_http_headers" => env_headers
        }
        when headers in [nil, %{}] and env_headers in [nil, %{}],
        server["transport"]
      ) and known_fields?(server["transport"], @http_transport_keys)
  end

  defp restorable(%{"transport" => transport} = server) do
    if known_fields?(server, @server_keys) and default_settings?(server) do
      restorable_transport(transport)
    else
      :error
    end
  end

  defp restorable(_server), do: :error

  defp restorable_transport(
         %{
           "type" => "streamable_http",
           "url" => url,
           "bearer_token_env_var" => nil,
           "http_headers" => headers,
           "env_http_headers" => env_headers
         } = transport
       )
       when is_binary(url) and url != "" and headers in [nil, %{}] and env_headers in [nil, %{}] do
    if known_fields?(transport, @http_transport_keys) do
      {:ok, %Registration{kind: :http, url: url}}
    else
      :error
    end
  end

  defp restorable_transport(
         %{"type" => "stdio", "command" => command, "args" => args, "env" => env, "env_vars" => env_vars, "cwd" => nil} =
           transport
       )
       when is_binary(command) and command != "" and is_list(args) and env in [nil, %{}] and env_vars == [] do
    if known_fields?(transport, @stdio_transport_keys) and Enum.all?(args, &is_binary/1) do
      {:ok, %Registration{kind: :stdio, command: command, args: args}}
    else
      :error
    end
  end

  defp restorable_transport(_transport), do: :error

  defp default_settings?(server) do
    server["enabled"] == true and is_nil(server["disabled_reason"]) and
      is_nil(server["startup_timeout_sec"]) and is_nil(server["tool_timeout_sec"]) and
      server["auth_status"] in [nil, "unsupported"] and is_nil(server["enabled_tools"]) and
      is_nil(server["disabled_tools"])
  end

  defp previous_registration(:missing), do: nil
  defp previous_registration({:replace, registration}), do: registration

  defp replace_with_current(binding, nil, opts), do: add_current(binding, opts)

  defp replace_with_current(binding, %Registration{}, opts) do
    with :ok <- remove(binding, opts), do: add_current(binding, opts)
  end

  defp restore(binding, previous, opts, mode) do
    with {:ok, servers} <- list(binding, opts) do
      server = Enum.find(servers, &(&1["name"] == @name))
      restore_from_state(binding, server, previous, opts, mode)
    end
  end

  defp restore_from_state(_binding, nil, nil, _opts, _mode), do: :ok

  defp restore_from_state(binding, nil, %Registration{} = previous, opts, :immediate) do
    with :ok <- add(binding, previous, opts), do: verify_restored(binding, previous, opts)
  end

  defp restore_from_state(_binding, nil, %Registration{}, _opts, :cas), do: stale_registration(nil)

  defp restore_from_state(binding, server, previous, opts, _mode) do
    cond do
      match?(%Registration{}, previous) and registration_matches?(server, previous) ->
        :ok

      current?(server) ->
        with :ok <- remove(binding, opts),
             :ok <- verify_missing(binding, opts),
             :ok <- add_previous(binding, previous, opts) do
          verify_restored(binding, previous, opts)
        end

      true ->
        stale_registration(server)
    end
  end

  defp rollback_failed_install(binding, previous, error, opts) do
    case restore(binding, previous, opts, :immediate) do
      :ok ->
        {:error, error}

      {:error, %Error{} = restore_error} ->
        {:error,
         Error.new(6, "mcp_rollback_failed", "The previous MCP registration could not be restored.",
           details: %{
             "replacement_error" => Error.to_map(error),
             "restore_error" => Error.to_map(restore_error)
           },
           changed: true
         )}
    end
  end

  defp verify_expected_state(binding, state, opts) do
    with {:ok, servers} <- list(binding, opts) do
      server = Enum.find(servers, &(&1["name"] == @name))

      case {state, server} do
        {:missing, nil} ->
          :ok

        {{:replace, registration}, server} when not is_nil(server) ->
          if registration_matches?(server, registration), do: :ok, else: stale_registration(server)

        _ ->
          stale_registration(server)
      end
    end
  end

  defp verify_current(binding, opts) do
    with {:ok, servers} <- list(binding, opts) do
      case Enum.find(servers, &(&1["name"] == @name)) do
        nil -> {:error, registration_verify_error(nil)}
        server -> if current?(server), do: :ok, else: {:error, registration_verify_error(server)}
      end
    end
  end

  defp verify_restored(binding, previous, opts) do
    with {:ok, servers} <- list(binding, opts) do
      server = Enum.find(servers, &(&1["name"] == @name))

      case {previous, server} do
        {nil, nil} ->
          :ok

        {%Registration{} = registration, server} when not is_nil(server) ->
          if registration_matches?(server, registration),
            do: :ok,
            else: {:error, registration_verify_error(server)}

        _ ->
          {:error, registration_verify_error(server)}
      end
    end
  end

  defp registration_matches?(server, %Registration{kind: :http, url: url}) do
    known_fields?(server, @server_keys) and default_settings?(server) and
      match?(
        %{
          "type" => "streamable_http",
          "url" => ^url,
          "bearer_token_env_var" => nil,
          "http_headers" => headers,
          "env_http_headers" => env_headers
        }
        when headers in [nil, %{}] and env_headers in [nil, %{}],
        server["transport"]
      ) and known_fields?(server["transport"], @http_transport_keys)
  end

  defp registration_matches?(server, %Registration{kind: :stdio, command: command, args: args}) do
    known_fields?(server, @server_keys) and default_settings?(server) and
      match?(
        %{
          "type" => "stdio",
          "command" => ^command,
          "args" => ^args,
          "env" => env,
          "env_vars" => [],
          "cwd" => nil
        }
        when env in [nil, %{}],
        server["transport"]
      ) and known_fields?(server["transport"], @stdio_transport_keys)
  end

  defp verify_missing(binding, opts) do
    with {:ok, servers} <- list(binding, opts) do
      if Enum.any?(servers, &(&1["name"] == @name)),
        do: stale_registration(Enum.find(servers, &(&1["name"] == @name))),
        else: :ok
    end
  end

  defp add_previous(_binding, nil, _opts), do: :ok
  defp add_previous(binding, %Registration{} = previous, opts), do: add(binding, previous, opts)

  defp add_current(binding, opts), do: add(binding, %Registration{kind: :http, url: @url}, opts)

  defp add(binding, %Registration{kind: :http, url: url}, opts) do
    mutation(binding, ["mcp", "add", @name, "--url", url], opts, "mcp_add")
  end

  defp add(binding, %Registration{kind: :stdio, command: command, args: args}, opts) do
    mutation(binding, ["mcp", "add", @name, "--", command | args], opts, "mcp_restore")
  end

  defp remove(binding, opts), do: mutation(binding, ["mcp", "remove", @name], opts, "mcp_remove")

  defp mutation(binding, args, opts, step) do
    case command(binding, args, opts, step) do
      {:ok, _output} -> :ok
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp command(binding, args, opts, step) do
    runner = Keyword.get(opts, :command_runner, &Command.run/3)
    timeout = Keyword.get(opts, :command_timeout, 5_000)

    case runner.(binding.path, args, timeout: timeout, max_output_bytes: 1_048_576) do
      {:ok, %{status: 0, output: output}} ->
        {:ok, output}

      {:ok, %{status: status, output: output}} ->
        {:error,
         Error.new(5, "codex_command_failed", "A Codex MCP configuration command failed.",
           details: %{"command" => args, "status" => status, "output" => String.trim(output)},
           step: step
         )}

      {:error, reason} ->
        {:error,
         Error.new(5, "codex_command_failed", "A Codex MCP configuration command failed.",
           details: %{"command" => args, "reason" => inspect(reason)},
           step: step
         )}
    end
  end

  defp invalid_list do
    Error.new(5, "codex_mcp_invalid", "Codex returned an invalid MCP server list.", step: "mcp_read")
  end

  defp non_restorable(server) do
    if tool_filters?(server) do
      Error.new(
        4,
        "mcp_registration_not_restorable",
        "The existing Codex Loops MCP registration has tool filters that `codex mcp add` cannot restore.",
        details: %{
          "registration" => server,
          "reason" => "codex_mcp_add_cannot_restore_tool_filters"
        }
      )
    else
      Error.new(
        4,
        "mcp_registration_not_restorable",
        "The existing Codex Loops MCP registration cannot be replaced safely.",
        details: %{"registration" => server}
      )
    end
  end

  defp tool_filters?(server) when is_map(server) do
    not is_nil(server["enabled_tools"]) or not is_nil(server["disabled_tools"])
  end

  defp tool_filters?(_server), do: false

  defp known_fields?(map, allowed) when is_map(map), do: Enum.all?(Map.keys(map), &(&1 in allowed))
  defp known_fields?(_map, _allowed), do: false

  defp stale_registration(server) do
    {:error,
     Error.new(4, "mcp_registration_changed", "The Codex Loops MCP registration changed during installation.",
       details: %{"registration" => server}
     )}
  end

  defp registration_verify_error(server) do
    Error.new(6, "mcp_registration_verify_failed", "Codex did not persist the exact Codex Loops HTTP registration.",
      details: %{"registration" => server},
      step: "mcp_verify"
    )
  end

  defp request_initialize(base_url, opts) do
    client = Keyword.get(opts, :mcp_http_client, &:httpc.request/4)
    timeout = Keyword.get(opts, :mcp_probe_timeout, 1_000)
    _ = Application.ensure_all_started(:inets)

    body =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => @probe_id,
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => @probe_protocol_version,
          "capabilities" => %{},
          "clientInfo" => %{"name" => "codex-loops-installer", "version" => PackageVersion.version()}
        }
      })

    url = String.trim_trailing(base_url, "/") <> "/mcp"
    headers = [{~c"accept", ~c"application/json, text/event-stream"}]

    case client.(
           :post,
           {String.to_charlist(url), headers, ~c"application/json", body},
           [timeout: timeout, connect_timeout: timeout],
           body_format: :binary
         ) do
      {:ok, {{_http_version, 200, _reason}, response_headers, response_body}} ->
        validate_initialize_response(response_headers, response_body, opts)

      {:ok, {{_http_version, status, _reason}, _headers, response_body}} ->
        {:error, endpoint_error(%{"status" => status, "body" => limited_body(response_body)})}

      {:error, reason} ->
        {:error, endpoint_error(%{"reason" => inspect(reason)})}
    end
  end

  defp validate_initialize_response(headers, body, opts) do
    max_body_bytes = Keyword.get(opts, :mcp_probe_max_body_bytes, 65_536)

    with true <- json_content_type?(headers),
         true <- is_binary(body) and byte_size(body) <= max_body_bytes,
         {:ok, response} <- Jason.decode(body),
         :ok <- valid_initialize_response(response) do
      :ok
    else
      _invalid -> {:error, endpoint_error(%{"body" => limited_body(body)})}
    end
  end

  defp valid_initialize_response(%{
         "jsonrpc" => "2.0",
         "id" => @probe_id,
         "result" => %{
           "protocolVersion" => @probe_protocol_version,
           "capabilities" => %{"tools" => %{"listChanged" => false}},
           "serverInfo" => %{"name" => "codex-loops", "version" => version}
         }
       }) do
    if version == PackageVersion.version(), do: :ok, else: :error
  end

  defp valid_initialize_response(_response), do: :error

  defp json_content_type?(headers) do
    Enum.any?(headers, fn {name, value} ->
      String.downcase(to_string(name)) == "content-type" and
        value |> to_string() |> String.downcase() |> String.split(";", parts: 2) |> hd() |> String.trim() ==
          "application/json"
    end)
  end

  defp normalize_probe_result(:ok), do: :ok
  defp normalize_probe_result({:error, %Error{} = error}), do: {:error, error}
  defp normalize_probe_result(other), do: {:error, endpoint_error(%{"result" => inspect(other)})}

  defp endpoint_error(details) do
    Error.new(6, "mcp_endpoint_invalid", "The managed scheduler did not expose the expected MCP protocol endpoint.",
      details: details,
      step: "mcp_endpoint_probe"
    )
  end

  defp limited_body(body) when is_binary(body), do: binary_part(body, 0, min(byte_size(body), 1_024))
  defp limited_body(body), do: inspect(body)
end
