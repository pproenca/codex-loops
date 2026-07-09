defmodule Workflow.CLI do
  @moduledoc "User-facing setup command for the Homebrew-owned Codex Loops runtime."

  import Bitwise, only: [band: 2]

  alias Workflow.PackageVersion

  @marketplace "codex-loops"
  @marketplace_source "pproenca/codex-loops"
  @plugin_id "codex-loops@codex-loops"
  @capability_commands [
    ["plugin", "marketplace", "add", "--help"],
    ["plugin", "add", "--help"],
    ["plugin", "marketplace", "list", "--help"],
    ["plugin", "list", "--help"]
  ]

  @type result :: {:ok, map()} | {:error, 1..6, map()}

  @spec main([String.t()]) :: :ok | no_return()
  def main(args \\ System.argv()) do
    case args do
      ["--version"] ->
        IO.puts("codex-loops #{PackageVersion.version()}")

      [] ->
        IO.puts(help())

      [arg] when arg in ["--help", "-h"] ->
        IO.puts(help())

      _other ->
        json? = "--json" in args

        case run(args) do
          {:ok, result} ->
            print_success(result, json?)

          {:error, status, error} ->
            print_error(error, json?)
            System.halt(status)
        end
    end

    :ok
  end

  @doc "Runs the installer contract without halting the VM."
  @spec run([String.t()], keyword()) :: result()
  def run(args, opts \\ []) when is_list(args) and is_list(opts) do
    with {:ok, mode} <- parse(args),
         {:ok, runtime} <- runtime(opts),
         {:ok, codex} <- codex(opts),
         {:ok, state} <- read_state(codex),
         {:ok, plan} <- plan(state),
         {:ok, changed?} <- execute(mode, plan, codex),
         {:ok, final_state} <- final_state(mode, plan, state, codex),
         :ok <- verify(mode, plan, final_state, runtime) do
      {:ok, success(runtime, codex, final_state, plan, changed?, mode)}
    end
  end

  defp parse(["install" | flags]) do
    allowed = ["--check", "--dry-run", "--json", "--verbose"]

    cond do
      Enum.any?(flags, &(&1 not in allowed)) ->
        usage_error("Unknown install option.")

      Enum.uniq(flags) != flags ->
        usage_error("Install options may be specified only once.")

      "--check" in flags and "--dry-run" in flags ->
        usage_error("--check and --dry-run are mutually exclusive.")

      true ->
        operation =
          cond do
            "--check" in flags -> :check
            "--dry-run" in flags -> :dry_run
            true -> :install
          end

        {:ok, %{operation: operation, json?: "--json" in flags, verbose?: "--verbose" in flags}}
    end
  end

  defp parse(_args), do: usage_error("Expected the install command.")

  defp runtime(opts) do
    root = Keyword.get(opts, :runtime_root) || System.get_env("CODEX_LOOPS_RUNTIME_ROOT")

    with true <- is_binary(root) and root != "",
         root = Path.expand(root),
         scheduler = Path.join([root, "scheduler", "bin", "agent_loops"]),
         mcp = Path.join([root, "mcp", "codex-loops-mcp"]),
         true <- executable?(scheduler),
         true <- executable?(mcp),
         {output, 0} <- System.cmd(mcp, ["--version"], stderr_to_stdout: true),
         "codex-loops-mcp " <> version <- String.trim(output),
         true <- version == PackageVersion.version() do
      {:ok, %{root: root, scheduler: scheduler, mcp: mcp, version: version}}
    else
      _other ->
        error(
          6,
          "runtime_invalid",
          "Codex Loops runtime files are missing or incompatible. Run: brew reinstall pproenca/codex-loops/codex-loops",
          %{runtime_root: root}
        )
    end
  end

  defp codex(opts) do
    bin =
      if Keyword.has_key?(opts, :codex_bin) do
        Keyword.get(opts, :codex_bin)
      else
        System.find_executable("codex")
      end

    if is_nil(bin) do
      error(
        3,
        "codex_missing",
        "Codex CLI was not found on PATH. Install it with:\n  brew install --cask codex"
      )
    else
      command = Keyword.get(opts, :command, &System.cmd(bin, &1, stderr_to_stdout: true))

      case Enum.find(@capability_commands, fn args ->
             case command.(args) do
               {output, 0} -> not String.contains?(output, "--json")
               _other -> true
             end
           end) do
        nil ->
          {:ok, %{bin: bin, command: command}}

        failed ->
          error(
            3,
            "codex_incompatible",
            "This Codex CLI does not support plugin marketplace installation. Update Codex, then rerun:\n  codex update",
            %{command: Enum.join(failed, " ")}
          )
      end
    end
  end

  defp read_state(codex) do
    with {:ok, marketplaces} <- json_command(codex, ["plugin", "marketplace", "list", "--json"]),
         {:ok, plugins} <- json_command(codex, ["plugin", "list", "--json"]) do
      {:ok,
       %{
         marketplace: find_marketplace(marketplaces["marketplaces"] || []),
         plugin: find_plugin(plugins["installed"] || [])
       }}
    end
  end

  defp plan(%{marketplace: marketplace, plugin: plugin}) do
    with {:ok, marketplace_action} <- marketplace_action(marketplace),
         {:ok, plugin_action} <- plugin_action(plugin, marketplace_action) do
      {:ok, Enum.reject([marketplace_action, plugin_action], &(&1 == :keep))}
    end
  end

  defp marketplace_action(nil), do: {:ok, :add_marketplace}

  defp marketplace_action(marketplace) do
    source = marketplace_source(marketplace)
    ref = marketplace_ref(marketplace)

    cond do
      not expected_source?(source) ->
        error(
          4,
          "marketplace_conflict",
          "Codex marketplace #{@marketplace} is owned by a conflicting source: #{source}",
          %{source: source}
        )

      ref == release_ref() ->
        {:ok, :keep}

      true ->
        {:ok, :replace_marketplace}
    end
  end

  defp plugin_action(nil, _marketplace_action), do: {:ok, :install_plugin}

  defp plugin_action(plugin, marketplace_action) do
    cond do
      plugin["marketplaceName"] != @marketplace ->
        error(
          4,
          "plugin_conflict",
          "Codex Loops plugin is installed from a conflicting marketplace.",
          %{marketplace: plugin["marketplaceName"]}
        )

      marketplace_action != :keep ->
        {:ok, :install_plugin}

      plugin["version"] != PackageVersion.version() ->
        {:ok, :install_plugin}

      plugin["installed"] != true or plugin["enabled"] != true ->
        {:ok, :install_plugin}

      true ->
        {:ok, :keep}
    end
  end

  defp execute(%{operation: operation}, _plan, _codex) when operation in [:check, :dry_run], do: {:ok, false}

  defp execute(%{operation: :install}, plan, codex) do
    Enum.reduce_while(plan, {:ok, false}, fn action, {:ok, changed?} ->
      case apply_action(action, codex) do
        :ok -> {:cont, {:ok, true}}
        {:error, _status, _error} = failure -> {:halt, put_changed(failure, changed?)}
      end
    end)
  end

  defp apply_action(:add_marketplace, codex), do: add_marketplace(codex)

  defp apply_action(:replace_marketplace, codex) do
    with :ok <- command(codex, ["plugin", "marketplace", "remove", @marketplace, "--json"]) do
      add_marketplace(codex)
    end
  end

  defp apply_action(:install_plugin, codex), do: command(codex, ["plugin", "add", @plugin_id, "--json"])

  defp add_marketplace(codex) do
    command(codex, [
      "plugin",
      "marketplace",
      "add",
      @marketplace_source,
      "--ref",
      release_ref(),
      "--json"
    ])
  end

  defp final_state(%{operation: :install}, _plan, _state, codex), do: read_state(codex)
  defp final_state(_mode, _plan, state, _codex), do: {:ok, state}

  defp verify(%{operation: :dry_run}, _plan, _state, _runtime), do: :ok

  defp verify(%{operation: :check}, [_action | _rest] = plan, _state, _runtime) do
    error(
      1,
      "state_missing",
      "Codex Loops is not fully installed.",
      %{plan: Enum.map(plan, &Atom.to_string/1)}
    )
  end

  defp verify(%{operation: :install}, _original_plan, state, _runtime) do
    case plan(state) do
      {:ok, []} ->
        :ok

      {:ok, remaining} ->
        error(
          6,
          "verification_failed",
          "Codex Loops installation could not be verified.",
          %{plan: Enum.map(remaining, &Atom.to_string/1)}
        )

      {:error, _status, _error} = failure ->
        failure
    end
  end

  defp verify(_mode, [], %{marketplace: marketplace, plugin: plugin}, _runtime)
       when not is_nil(marketplace) and not is_nil(plugin), do: :ok

  defp verify(_mode, _plan, state, _runtime) do
    error(6, "verification_failed", "Codex Loops installation could not be verified.", state)
  end

  defp success(runtime, codex, state, plan, changed?, mode) do
    %{
      ok: true,
      changed: changed?,
      runtime: runtime,
      codex: %{path: codex.bin},
      marketplace: marketplace_result(state.marketplace),
      plugin: plugin_result(state.plugin),
      plan: Enum.map(plan, &Atom.to_string/1),
      mode: mode.operation,
      next_steps: ["Open a new Codex thread and ask: Use the codex-loops skill."]
    }
  end

  defp json_command(codex, args) do
    case codex.command.(args) do
      {output, 0} ->
        case Jason.decode(output) do
          {:ok, payload} -> {:ok, payload}
          {:error, reason} -> command_error(args, "invalid JSON: #{Exception.message(reason)}")
        end

      {output, status} ->
        command_error(args, "exit #{status}: #{String.trim(output)}")
    end
  end

  defp command(codex, args) do
    case codex.command.(args) do
      {_output, 0} -> :ok
      {output, status} -> command_error(args, "exit #{status}: #{String.trim(output)}")
    end
  end

  defp command_error(args, detail) do
    error(
      5,
      "codex_command_failed",
      "Codex command failed unexpectedly.",
      %{command: Enum.join(args, " "), detail: detail}
    )
  end

  defp find_marketplace(marketplaces), do: Enum.find(marketplaces, &(&1["name"] == @marketplace))

  defp find_plugin(plugins), do: Enum.find(plugins, &(&1["pluginId"] == @plugin_id))

  defp marketplace_result(nil), do: nil

  defp marketplace_result(marketplace) do
    %{
      name: marketplace["name"],
      source: marketplace_source(marketplace),
      ref: marketplace_ref(marketplace)
    }
  end

  defp plugin_result(nil), do: nil

  defp plugin_result(plugin) do
    %{
      id: plugin["pluginId"],
      installed: plugin["installed"] == true,
      enabled: plugin["enabled"] == true,
      version: plugin["version"]
    }
  end

  defp marketplace_source(marketplace) do
    get_in(marketplace, ["marketplaceSource", "source"]) || marketplace["source"] || "unknown"
  end

  defp marketplace_ref(marketplace) do
    get_in(marketplace, ["marketplaceSource", "ref"]) ||
      get_in(marketplace, ["marketplaceSource", "refName"]) || marketplace["ref"]
  end

  defp expected_source?(source) do
    source
    |> String.trim()
    |> String.replace(~r{^(https://github\.com/|git@github\.com:)}, "")
    |> String.trim_trailing(".git")
    |> Kernel.==(@marketplace_source)
  end

  defp release_ref, do: "v#{PackageVersion.version()}"

  defp executable?(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, mode: mode}} -> band(mode, 0o111) != 0
      _other -> false
    end
  end

  defp usage_error(message), do: error(2, "usage", message <> "\n\n" <> help())

  defp error(status, code, message, details \\ nil) do
    {:error, status, %{ok: false, changed: false, code: code, message: message, details: details}}
  end

  defp put_changed({:error, status, error}, changed?), do: {:error, status, %{error | changed: changed?}}

  defp print_success(result, true), do: IO.puts(Jason.encode!(result))

  defp print_success(result, false) do
    action = if result.changed, do: "installed", else: "ready"

    IO.puts("""
    Codex Loops is #{action}.

    Runtime:
      Version: #{result.runtime.version}
      Scheduler: #{result.runtime.scheduler}
      MCP: #{result.runtime.mcp}

    Next:
      #{hd(result.next_steps)}
    """)
  end

  defp print_error(error, true), do: IO.puts(:stderr, Jason.encode!(%{ok: false, error: error}))
  defp print_error(error, false), do: IO.puts(:stderr, error.message)

  defp help do
    String.trim_trailing("""
    Usage: codex-loops install [--check | --dry-run] [--json] [--verbose]
           codex-loops --version

    Commands:
      install      Install or verify the Codex Loops plugin.

    Options:
      --check      Verify without changing Codex state.
      --dry-run    Show the changes without applying them.
      --json       Emit machine-readable output.
      --verbose    Include resolved paths and commands.
      --version    Show the Codex Loops package version.
      --help       Show this help.
      -h           Show this help.
    """)
  end
end
