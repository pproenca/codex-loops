defmodule Workflow.CLI.RunCommand do
  @moduledoc "Runs one workflow through the public scheduler API."

  alias Workflow.CLI
  alias Workflow.CLI.ServeCommand
  alias Workflow.MCP.SchedulerClient

  @type result :: {:ok, map()} | {:error, 1..6, map()}

  @spec run([String.t()], keyword()) :: result()
  def run(args, opts \\ []) do
    with {:ok, input} <- parse(args),
         {:ok, script_path} <- script_path(input.script),
         client_opts = client_opts(input.server),
         :ok <- scheduler_ready(client_opts, opts),
         {:ok, _validation} <- scheduler_result(SchedulerClient.validate_workflow(script_path, client_opts)),
         run_id = input.run_id || run_id(script_path, opts),
         {:ok, started} <- start(script_path, run_id, input.provider, client_opts),
         ui_url = ui_url(client_opts, run_id),
         {:ok, opened?, warning} <- maybe_open(ui_url, input.open?, opts) do
      {:ok,
       %{
         ok: true,
         command: :run,
         script_path: script_path,
         workflow_name: get_in(started, ["data", "workflow_name"]),
         run_id: run_id,
         provider: input.provider,
         state: get_in(started, ["data", "state"]),
         ui_url: ui_url,
         opened: opened?,
         warning: warning
       }}
    end
  end

  defp parse(args) do
    {flags, positional, invalid} =
      OptionParser.parse(args,
        strict: [open: :boolean, provider: :string, run_id: :string, server: :string, json: :boolean],
        aliases: [o: :open]
      )

    cond do
      invalid != [] ->
        usage_error("Unknown run option: #{invalid |> hd() |> elem(0)}")

      length(positional) != 1 ->
        usage_error("Expected exactly one workflow script path.")

      Keyword.get(flags, :provider, "codex") not in ["codex", "mock"] ->
        usage_error("--provider must be codex or mock.")

      true ->
        {:ok,
         %{
           script: hd(positional),
           open?: Keyword.get(flags, :open, false),
           provider: Keyword.get(flags, :provider, "codex"),
           run_id: Keyword.get(flags, :run_id),
           server: Keyword.get(flags, :server)
         }}
    end
  end

  defp script_path(path) do
    expanded = Path.expand(path)

    if File.regular?(expanded) do
      {:ok, expanded}
    else
      CLI.error(2, "script_not_found", "Workflow script does not exist: #{expanded}", %{script_path: expanded})
    end
  end

  defp scheduler_ready(client_opts, opts) do
    case SchedulerClient.health(client_opts) do
      {:ok, _payload} ->
        :ok

      {:error, reason} ->
        start_local_scheduler(client_opts, opts, reason)
    end
  end

  defp start_local_scheduler(client_opts, opts, health_error) do
    config = SchedulerClient.config(client_opts)

    if SchedulerClient.local?(config) do
      case ServeCommand.run(["--host", config.host, "--port", Integer.to_string(config.port)], opts) do
        {:ok, _result} -> :ok
        {:error, _status, _error} = failure -> failure
      end
    else
      CLI.error(
        6,
        "scheduler_unavailable",
        "The configured scheduler is not reachable and cannot be started locally.",
        %{reason: health_error, server: config.base_url}
      )
    end
  end

  defp start(script_path, run_id, provider, client_opts) do
    %{"script_path" => script_path, "run_id" => run_id, "provider" => provider}
    |> SchedulerClient.start_run(client_opts)
    |> scheduler_result()
  end

  defp scheduler_result({:ok, payload}), do: {:ok, payload}

  defp scheduler_result({:scheduler_error, %{"error" => scheduler_error}}) do
    CLI.error(
      4,
      scheduler_error["code"] || "scheduler_error",
      scheduler_error["message"] || "The scheduler rejected the request.",
      scheduler_error["details"]
    )
  end

  defp scheduler_result({:unexpected, status, payload}) do
    CLI.error(6, "scheduler_response", "The scheduler returned an unexpected response.", %{
      status: status,
      payload: payload
    })
  end

  defp scheduler_result({:error, reason}) do
    CLI.error(6, "scheduler_unavailable", "Could not reach the Codex Loops scheduler.", %{reason: reason})
  end

  defp run_id(script_path, opts) do
    generator = Keyword.get(opts, :run_id, &default_run_id/1)
    generator.(script_path)
  end

  defp default_run_id(script_path) do
    name =
      script_path
      |> Path.basename(".exs")
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9_-]+/u, "-")
      |> String.trim("-")

    name = if name == "", do: "run", else: name

    "#{name}-#{System.system_time(:millisecond)}"
  end

  defp ui_url(client_opts, run_id) do
    SchedulerClient.run_ui_url(run_id, client_opts)
  end

  defp maybe_open(_url, false, _opts), do: {:ok, false, nil}

  defp maybe_open(url, true, opts) do
    opener = Keyword.get(opts, :open_url, &open_url/1)

    case opener.(url) do
      :ok -> {:ok, true, nil}
      {:error, reason} -> {:ok, false, "Run started, but the browser could not be opened: #{reason}"}
    end
  end

  defp open_url(url) do
    command =
      System.get_env("CODEX_LOOPS_OPEN_BIN") ||
        if(match?({:unix, :darwin}, :os.type()), do: "open", else: "xdg-open")

    case System.find_executable(command) do
      nil -> {:error, "#{command} was not found on PATH"}
      executable -> command_result(System.cmd(executable, [url], stderr_to_stdout: true))
    end
  end

  defp command_result({_output, 0}), do: :ok
  defp command_result({output, status}), do: {:error, "exit #{status}: #{String.trim(output)}"}

  defp client_opts(nil), do: []
  defp client_opts(server), do: [base_url: server]

  defp usage_error(message), do: CLI.error(2, "usage", message <> "\n\n" <> usage())

  defp usage do
    "Usage: codex-loops run WORKFLOW.exs [--open] [--provider codex|mock] [--run-id ID] [--server URL]"
  end
end
