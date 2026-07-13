defmodule Workflow.CLI do
  @moduledoc "User-facing command dispatcher for installing and operating Codex Loops."

  alias Workflow.Install
  alias Workflow.Install.Error
  alias Workflow.Install.Service
  alias Workflow.PackageVersion

  @api_version "codex-loops.cli.v1"

  @type result :: {:ok, map()} | {:error, 1..6, map()}

  @spec main([String.t()]) :: :ok | no_return()
  def main(args \\ System.argv()) do
    json? = "--json" in args

    case args do
      [] ->
        IO.puts(help())

      [arg] when arg in ["--help", "-h"] ->
        IO.puts(help())

      ["--version"] ->
        IO.puts("codex-loops #{PackageVersion.version()}")

      _ ->
        case run(args) do
          {:ok, envelope} ->
            print(envelope, json?)

          {:error, status, envelope} ->
            print_error(envelope, json?)
            System.halt(status)
        end
    end

    :ok
  end

  @spec run([String.t()], keyword()) :: result()
  def run(args, opts \\ []) do
    case parse(args) do
      {:ok, command, command_opts} -> execute(command, Keyword.merge(opts, command_opts))
      {:error, %Error{} = error} -> error_result(error)
    end
  end

  @spec help() :: String.t()
  def help do
    String.trim_trailing("""
    Usage: codex-loops COMMAND [OPTIONS]

    Commands:
      install [--codex ABSOLUTE_PATH] [--check | --dry-run] [--json]
      check [--codex ABSOLUTE_PATH] [--json]
      dry-run [--codex ABSOLUTE_PATH] [--json]
      serve [--json]
      stop [--json]
      restart [--json]
      status [--json]
      doctor [--json]

    Options:
      --version  Show the package version.
      --help     Show this help.
      -h         Show this help.
    """)
  end

  defp parse(["install" | args]), do: parse_install(args, nil)
  defp parse(["check" | args]), do: parse_install(args, :check)
  defp parse(["dry-run" | args]), do: parse_install(args, :dry_run)

  defp parse([command | args]) when command in ["serve", "stop", "restart", "status", "doctor"],
    do: parse_service(command, args)

  defp parse(_args), do: {:error, usage_error("Expected a supported Codex Loops command.")}

  defp parse_install(args, forced_mode) do
    {parsed, remaining, invalid} =
      OptionParser.parse(args,
        strict: [codex: :string, check: :boolean, dry_run: :boolean, json: :boolean],
        aliases: []
      )

    cond do
      remaining != [] or invalid != [] ->
        {:error, usage_error("Unknown install option.")}

      duplicated?(parsed) ->
        {:error, usage_error("Install options may be specified only once.")}

      Keyword.get(parsed, :check, false) and Keyword.get(parsed, :dry_run, false) ->
        {:error, usage_error("--check and --dry-run are mutually exclusive.")}

      forced_mode == :check and Keyword.get(parsed, :dry_run, false) ->
        {:error, usage_error("The check command cannot be combined with --dry-run.")}

      forced_mode == :dry_run and Keyword.get(parsed, :check, false) ->
        {:error, usage_error("The dry-run command cannot be combined with --check.")}

      true ->
        mode =
          forced_mode ||
            cond do
              Keyword.get(parsed, :check, false) -> :check
              Keyword.get(parsed, :dry_run, false) -> :dry_run
              true -> :install
            end

        opts =
          parsed
          |> Keyword.take([:codex, :json])
          |> Keyword.put(:mode, mode)

        {:ok, :install, opts}
    end
  end

  defp parse_service(command, args) do
    {parsed, remaining, invalid} = OptionParser.parse(args, strict: [json: :boolean], aliases: [])

    if remaining == [] and invalid == [] and not duplicated?(parsed) do
      {:ok, String.to_existing_atom(command), parsed}
    else
      {:error, usage_error("#{command} accepts only --json.")}
    end
  end

  defp duplicated?(options) do
    keys = Keyword.keys(options)
    Enum.uniq(keys) != keys
  end

  defp execute(:install, opts) do
    mode = Keyword.fetch!(opts, :mode)
    opts = Keyword.drop(opts, [:mode, :json, :verbose])
    command = if mode == :install, do: "install", else: mode_name(mode)

    case Install.run(mode, opts) do
      {:ok, data} -> success(command, data)
      {:error, %Error{} = error} -> error_result(error)
    end
  end

  defp execute(:doctor, opts) do
    case Install.doctor(Keyword.delete(opts, :json)) do
      {:ok, data} -> success("doctor", data)
      {:error, %Error{} = error} -> error_result(error)
    end
  end

  defp execute(command, opts) when command in [:serve, :stop, :restart, :status] do
    operation = service_operation(command)
    verify_binding? = command in [:serve, :restart]

    with {:ok, config} <-
           opts
           |> Keyword.delete(:json)
           |> Keyword.put(:verify_binding, verify_binding?)
           |> Install.service_config(),
         {:ok, data} <- operation.(config, Keyword.delete(opts, :json)) do
      success(to_string(command), data)
    else
      {:error, %Error{} = error} -> error_result(error)
    end
  end

  defp service_operation(:serve), do: &Service.start/2
  defp service_operation(:stop), do: &Service.stop/2
  defp service_operation(:restart), do: &Service.restart/2
  defp service_operation(:status), do: &Service.status/2

  defp success(command, data) do
    {:ok,
     %{
       "api_version" => @api_version,
       "ok" => true,
       "changed" => Map.get(data, "changed", false),
       "command" => command,
       "data" => data
     }}
  end

  defp error_result(%Error{} = error) do
    {:error, error.status,
     %{
       "api_version" => @api_version,
       "ok" => false,
       "changed" => error.changed,
       "error" => Error.to_map(error)
     }}
  end

  defp usage_error(message), do: Error.new(2, "usage", message)
  defp mode_name(:dry_run), do: "dry-run"
  defp mode_name(mode), do: to_string(mode)

  defp print(envelope, true), do: IO.puts(Jason.encode!(envelope))

  defp print(envelope, false) do
    data = envelope["data"]
    IO.puts("Codex Loops #{envelope["command"]} succeeded.")

    if plan = data["plan"] do
      IO.puts("Plan: " <> if(plan == [], do: "no changes", else: Enum.join(plan, ", ")))
    end

    Enum.each(Map.get(data, "warnings", []), fn warning ->
      IO.puts(:stderr, "Warning [#{warning["code"]}]: installation cleanup needs attention")
    end)

    Enum.each(Map.get(data, "next_steps", []), &IO.puts("Next: #{&1}"))
  end

  defp print_error(envelope, true), do: IO.puts(:stderr, Jason.encode!(envelope))

  defp print_error(envelope, false) do
    error = envelope["error"]
    IO.puts(:stderr, "Error [#{error["code"]}]: #{error["message"]}")
  end
end
