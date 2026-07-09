defmodule Workflow.MCP.SchedulerClient do
  @moduledoc """
  HTTP client for the local workflow scheduler API used by the MCP adapter.

  This module deliberately knows only the published scheduler HTTP surface. It
  does not call `Workflow.Scheduler`, `Workflow.Journal`, or any run internals.
  """

  @default_timeout_ms 5_000

  @type config :: %{
          required(:base_url) => String.t(),
          required(:host) => String.t(),
          required(:port) => non_neg_integer(),
          required(:protocol) => String.t()
        }

  @type scheduler_result ::
          {:ok, map()}
          | {:scheduler_error, map()}
          | {:unexpected, non_neg_integer(), term()}
          | {:error, String.t()}

  @spec config() :: config()
  def config do
    case System.get_env("CODEX_LOOPS_SCHEDULER_URL") do
      nil -> env_config()
      "" -> env_config()
      url -> url_config(url)
    end
  end

  @spec health() :: {:ok, map()} | {:error, String.t()}
  def health do
    case request(:get, "/api/health") do
      {:ok, 200, %{"api_version" => "scheduler.v1", "data" => %{"status" => "ok"}} = payload} ->
        {:ok, payload}

      {:ok, status, payload} ->
        {:error, "Health check returned HTTP #{status}: #{inspect(payload)}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec validate_workflow(String.t()) :: scheduler_result()
  def validate_workflow(script_path) when is_binary(script_path) do
    scheduler_request(:post, "/api/workflows/validate", %{"script_path" => script_path})
  end

  @spec start_run(map()) :: scheduler_result()
  def start_run(attrs) when is_map(attrs) do
    scheduler_request(:post, "/api/runs", attrs)
  end

  @spec get_run(String.t()) :: scheduler_result()
  def get_run(run_id) when is_binary(run_id) do
    scheduler_request(:get, "/api/runs/" <> path_segment(run_id))
  end

  @spec get_run_events(String.t()) :: scheduler_result()
  def get_run_events(run_id) when is_binary(run_id) do
    scheduler_request(:get, "/api/runs/" <> path_segment(run_id) <> "/events")
  end

  @spec resume_run(String.t(), map()) :: scheduler_result()
  def resume_run(run_id, attrs \\ %{}) when is_binary(run_id) and is_map(attrs) do
    scheduler_request(:post, "/api/runs/" <> path_segment(run_id) <> "/resume", attrs)
  end

  defp scheduler_request(method, path, body \\ nil) do
    case request(method, path, body) do
      {:ok, status, %{"api_version" => "scheduler.v1", "data" => _data} = payload}
      when status in 200..299 ->
        {:ok, payload}

      {:ok, _status, %{"api_version" => "scheduler.v1", "error" => %{} = _error} = payload} ->
        {:scheduler_error, payload}

      {:ok, status, payload} ->
        {:unexpected, status, payload}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec request(:get | :post, String.t(), map() | nil) ::
          {:ok, non_neg_integer(), term()} | {:error, String.t()}
  def request(method, path, body \\ nil) when method in [:get, :post] and is_binary(path) do
    config = config()
    url = config.base_url <> path

    with :ok <- ensure_http_started(config.protocol),
         {:ok, status, response_body} <- http_request(method, url, body),
         {:ok, payload} <- decode_body(response_body) do
      {:ok, status, payload}
    end
  end

  @spec request_timeout_ms() :: pos_integer()
  def request_timeout_ms do
    case System.get_env("CODEX_LOOPS_SCHEDULER_REQUEST_TIMEOUT_MS") do
      nil -> @default_timeout_ms
      "" -> @default_timeout_ms
      raw -> parse_positive_integer(raw, @default_timeout_ms)
    end
  end

  defp env_config do
    host = System.get_env("CODEX_LOOPS_SCHEDULER_HOST", "127.0.0.1")
    port = "CODEX_LOOPS_SCHEDULER_PORT" |> System.get_env("47125") |> parse_positive_integer(47_125)

    %{
      base_url: "http://" <> format_host(host) <> ":#{port}",
      host: host,
      port: port,
      protocol: "http:"
    }
  end

  defp url_config(raw) do
    uri = URI.parse(raw)
    protocol = (uri.scheme || "http") <> ":"
    host = uri.host || "127.0.0.1"
    port = uri.port || default_port(protocol)

    %{
      base_url: URI.to_string(%URI{scheme: uri.scheme || "http", host: host, port: port}),
      host: host,
      port: port,
      protocol: protocol
    }
  end

  defp default_port("https:"), do: 443
  defp default_port(_protocol), do: 80

  defp format_host(host) do
    if String.contains?(host, ":") and not String.starts_with?(host, "[") do
      "[" <> host <> "]"
    else
      host
    end
  end

  defp ensure_http_started("https:") do
    with {:ok, _ssl} <- Application.ensure_all_started(:ssl),
         {:ok, _inets} <- Application.ensure_all_started(:inets) do
      :ok
    else
      {:error, reason} -> {:error, "could not start HTTP client applications: #{inspect(reason)}"}
    end
  end

  defp ensure_http_started(_protocol) do
    case Application.ensure_all_started(:inets) do
      {:ok, _apps} -> :ok
      {:error, reason} -> {:error, "could not start HTTP client application: #{inspect(reason)}"}
    end
  end

  defp http_request(:get, url, nil) do
    case :httpc.request(:get, {String.to_charlist(url), headers()}, http_options(), body_format: :binary) do
      {:ok, {{_version, status, _reason}, _headers, body}} -> {:ok, status, normalize_body(body)}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  defp http_request(:post, url, body) when is_map(body) do
    encoded = Jason.encode!(body)

    case :httpc.request(
           :post,
           {String.to_charlist(url), headers(), ~c"application/json", encoded},
           http_options(),
           body_format: :binary
         ) do
      {:ok, {{_version, status, _reason}, _headers, response_body}} ->
        {:ok, status, normalize_body(response_body)}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  defp headers, do: [{~c"accept", ~c"application/json"}]

  defp http_options do
    timeout = request_timeout_ms()
    [timeout: timeout, connect_timeout: timeout]
  end

  defp normalize_body(body) when is_binary(body), do: body
  defp normalize_body(body) when is_list(body), do: List.to_string(body)

  defp decode_body(""), do: {:ok, nil}

  defp decode_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, payload} ->
        {:ok, payload}

      {:error, error} ->
        {:error, "scheduler returned non-JSON response: #{Exception.message(error)}"}
    end
  end

  defp parse_positive_integer(raw, fallback) do
    case Integer.parse(to_string(raw)) do
      {value, ""} when value > 0 -> value
      _other -> fallback
    end
  end

  defp path_segment(value), do: URI.encode(value, &path_segment_unreserved?/1)

  defp path_segment_unreserved?(character)
       when character in ?a..?z or character in ?A..?Z or character in ?0..?9 or character in [?-, ?., ?_, ?~], do: true

  defp path_segment_unreserved?(_character), do: false
end
