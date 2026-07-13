defmodule Workflow.Provider.Codex do
  @moduledoc """
  Codex provider backed by the scheduler-owned, long-lived app-server.

  `Workflow.Provider.Codex.AppServer` owns one supervised OS process and performs
  only bounded JSON-RPC routing. This module runs in the writer's caller process,
  folds its correlated notifications, invokes the activity sink, and returns the
  normal `Workflow.Provider` result.

  A transport loss after `turn/start` was sent is intentionally not converted to
  an ordinary provider failure. The caller exits, leaving the already-durable
  `agent_started` event unsettled so resume records `outcome_unknown` and never
  redelivers a possibly-paid attempt.
  """
  @behaviour Workflow.Provider

  alias Workflow.Provider.Codex.AppServer
  alias Workflow.Provider.Codex.AppServer.TurnRequest
  alias Workflow.Provider.Codex.StreamAccumulator
  alias Workflow.Schema

  @timeout_detail %{"message" => "codex turn timed out"}
  @default_timeout 30 * 60 * 1_000
  @max_prompt_bytes 16 * 1_024 * 1_024

  @impl true
  def run_agent(prompt, schema, _key, opts) do
    schema = schema && Schema.new(schema)
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    accumulator = StreamAccumulator.new(schema, Keyword.get(opts, :activity_sink))

    with :ok <- validate_prompt(prompt),
         {:ok, command} <- command(opts),
         {:ok, execution} <- execution(opts),
         {:ok, ref, owner} <-
           AppServer.start_turn(%TurnRequest{
             prompt: prompt,
             schema: schema && Schema.strict_map(schema),
             cwd: execution.cwd,
             model: model(opts),
             thread_sandbox: execution.thread_sandbox,
             turn_sandbox: execution.turn_sandbox,
             command: command,
             timeout: timeout
           }) do
      monitor = Process.monitor(owner)

      try do
        await_turn(ref, monitor, accumulator, false, timeout + 1_000)
      after
        Process.demonitor(monitor, [:flush])
      end
    else
      {:error, {:provider_failure, _kind, _detail, _usage, _activity} = failure} ->
        {:error, failure}

      {:error, :outcome_unknown, detail} ->
        exit({:codex_turn_outcome_unknown, detail})

      {:error, kind, detail} when kind in [:unavailable, :backend] ->
        {:error, provider_failure(accumulator, kind, detail)}
    end
  end

  @doc """
  The production app-server command. Installation configures the scheduler with
  the exact bound Codex executable; the provider appends only `app-server` and
  sends per-turn settings over JSON-RPC. The shared app-server owner revalidates
  the persisted path and version immediately before opening the process.
  """
  @spec default_command() :: {String.t(), [String.t()]}
  def default_command do
    case default_command_result() do
      {:ok, command} -> command
      {:error, {:provider_failure, :unavailable, detail, _usage, _activity}} -> raise detail["message"]
    end
  end

  defp await_turn(ref, monitor, accumulator, uncertain?, timeout) do
    case AppServer.next_event(ref, monitor, timeout) do
      {:event, event} ->
        await_turn(ref, monitor, StreamAccumulator.observe_map(accumulator, event), uncertain?, timeout)

      :turn_start_sent ->
        await_turn(ref, monitor, accumulator, true, timeout)

      :accepted ->
        await_turn(ref, monitor, accumulator, true, timeout)

      {:terminal, :completed} ->
        StreamAccumulator.finish(accumulator)

      {:terminal, {:error, kind, detail}} ->
        {:error, provider_failure(accumulator, kind, detail)}

      {:transport_lost, detail} ->
        exit({:codex_turn_outcome_unknown, detail})

      {:owner_down, reason} when uncertain? ->
        exit({:codex_turn_outcome_unknown, %{"message" => "Codex app-server owner crashed", "reason" => inspect(reason)}})

      {:owner_down, reason} ->
        detail = %{"message" => "Codex app-server owner crashed before turn start", "reason" => inspect(reason)}
        {:error, provider_failure(accumulator, :unavailable, detail)}

      :timeout ->
        AppServer.cancel(ref)
        {:error, provider_failure(accumulator, :timeout, @timeout_detail)}
    end
  end

  defp provider_failure(%StreamAccumulator{failure: {kind, detail}} = accumulator, _kind, _detail) do
    {usage, activity} = StreamAccumulator.partial(accumulator)
    {:provider_failure, kind, detail, usage, activity}
  end

  defp provider_failure(accumulator, kind, detail) do
    {usage, activity} = StreamAccumulator.partial(accumulator)
    {:provider_failure, kind, failure_detail(kind, detail), usage, activity}
  end

  defp failure_detail(:unavailable, detail) when is_map(detail) do
    detail
    |> Map.put_new("config", "codex_command")
    |> Map.put_new(
      "hint",
      "Run `codex-loops install --codex /absolute/path/to/codex` to bind a tested Codex command."
    )
  end

  defp failure_detail(_kind, detail), do: detail

  defp command(opts) do
    with {:ok, {path, prefix}} <- base_command(opts),
         true <- is_binary(path) and path != "" and is_list(prefix) and Enum.all?(prefix, &is_binary/1) do
      {:ok, {path, prefix ++ app_server_args()}}
    else
      false -> {:error, unavailable_failure("invalid Codex command configuration")}
      {:error, failure} -> {:error, failure}
    end
  end

  defp validate_prompt(prompt) when is_binary(prompt) and byte_size(prompt) <= @max_prompt_bytes, do: :ok

  defp validate_prompt(prompt) when is_binary(prompt) do
    {:error,
     {:provider_failure, :model_limit,
      %{
        "message" => "codex prompt exceeded the provider input limit",
        "maxBytes" => @max_prompt_bytes
      }, nil, []}}
  end

  defp validate_prompt(_prompt) do
    {:error, {:provider_failure, :backend, %{"message" => "codex provider prompt must be a string"}, nil, []}}
  end

  defp base_command(opts) do
    case Keyword.fetch(opts, :command) do
      {:ok, command} -> {:ok, command}
      :error -> configured_command_result()
    end
  end

  defp default_command_result do
    with {:ok, {path, prefix}} <- configured_command_result() do
      {:ok, {path, prefix ++ app_server_args()}}
    end
  end

  defp configured_command_result do
    case Application.fetch_env(:codex_loops, :codex_command) do
      {:ok, {path, prefix}} when is_binary(path) and path != "" and is_list(prefix) ->
        if Enum.all?(prefix, &is_binary/1) do
          {:ok, {path, prefix}}
        else
          {:error, unavailable_failure("invalid Codex command configuration")}
        end

      :error ->
        {:error, unavailable_failure("Codex command was not configured")}

      {:ok, value} ->
        {:error, unavailable_failure("invalid Codex command configuration: #{inspect(value)}")}
    end
  end

  defp app_server_args do
    ["app-server"]
  end

  defp execution(opts) do
    requested_cwd = Keyword.get(opts, :cwd) || Keyword.get(opts, :workspace_root)

    case Application.get_env(:codex_loops, :codex_execution) do
      {:sandboxed, workdir} when is_binary(workdir) and workdir != "" ->
        cwd = Path.expand(workdir)

        {:ok,
         %{
           cwd: cwd,
           thread_sandbox: "workspace-write",
           turn_sandbox: %{
             "type" => "workspaceWrite",
             "writableRoots" => [cwd],
             "networkAccess" => false
           }
         }}

      nil ->
        cwd = requested_cwd || File.cwd!()

        if is_binary(cwd) and cwd != "" do
          {:ok,
           %{
             cwd: Path.expand(cwd),
             thread_sandbox: "danger-full-access",
             turn_sandbox: %{"type" => "dangerFullAccess"}
           }}
        else
          {:error, unavailable_failure("invalid Codex working directory")}
        end

      invalid ->
        {:error, unavailable_failure("invalid normalized Codex execution config: #{inspect(invalid)}")}
    end
  end

  defp model(opts) do
    case Keyword.get(opts, :model) || Application.get_env(:codex_loops, :codex_model) do
      model when is_binary(model) and model != "" -> model
      _unset -> nil
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
end
