defmodule Workflow.MCP.AnubisStdio do
  @moduledoc """
  Anubis-backed stdio entrypoint for the packaged `codex-loops-mcp` executable.

  This is the supported MCP product path. It runs the Anubis server over stdio
  and owns cleanup of any scheduler lifecycle it started for the session.
  """

  alias Anubis.Server.Registry, as: AnubisRegistry
  alias Anubis.Server.Transport.STDIO
  alias Workflow.MCP.AnubisServer
  alias Workflow.MCP.AnubisServer.ToolHelpers
  alias Workflow.PackageVersion

  @spec main([String.t()]) :: :ok | {:error, term()} | no_return()
  def main(args \\ System.argv()) do
    main(args, [])
  end

  @doc false
  @spec main([String.t()], keyword()) :: :ok | {:error, term()} | no_return()
  def main(args, opts) when is_list(args) and is_list(opts) do
    case args do
      [] ->
        run(opts)

      ["--stdio"] ->
        run(opts)

      ["--version"] ->
        IO.puts(
          Keyword.get(opts, :output_device, :stdio),
          "codex-loops-mcp #{PackageVersion.version()}"
        )

      [help_arg] when help_arg in ["--help", "-h"] ->
        IO.puts(
          Keyword.get(opts, :output_device, :stdio),
          help()
        )

      _other ->
        IO.puts(
          Keyword.get(opts, :error_device, :stderr),
          "Invalid arguments.\n\n" <> help()
        )

        if Keyword.get(opts, :halt?, true) do
          System.halt(2)
        else
          {:error, 2}
        end
    end
  end

  defp run(opts) do
    io_device = Keyword.get(opts, :io_device, :stdio)

    with {:ok, task_supervisor} <- start_task_supervisor() do
      run_with_supervisor(task_supervisor, io_device)
    end
  end

  defp run_with_supervisor(task_supervisor, io_device) do
    with {:ok, session} <- start_session() do
      run_with_session(session, io_device)
    end
  after
    stop_supervisor(task_supervisor)
  end

  defp run_with_session(session, io_device) do
    with {:ok, transport} <- start_transport(io_device) do
      wait_for_transport(transport)
      stop_process(transport)
      :ok
    end
  after
    ToolHelpers.stop_stored_lifecycle()
    stop_process(session)
  end

  defp start_task_supervisor do
    Task.Supervisor.start_link(name: task_supervisor_name())
  end

  defp start_session do
    Anubis.Server.Session.start_link(
      session_id: "stdio",
      server_module: AnubisServer,
      name: session_name(),
      transport: [layer: STDIO, name: transport_name()],
      task_supervisor: task_supervisor_name()
    )
  end

  defp start_transport(io_device) do
    STDIO.start_link(
      server: AnubisServer,
      name: transport_name(),
      io_device: io_device
    )
  end

  defp wait_for_transport(transport) do
    ref = Process.monitor(transport)

    receive do
      {:DOWN, ^ref, :process, ^transport, _reason} -> :ok
    end
  end

  defp stop_process(pid) when is_pid(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid, :normal, 1_000)
  catch
    :exit, _reason -> :ok
  end

  defp stop_supervisor(pid) when is_pid(pid) do
    if Process.alive?(pid), do: Supervisor.stop(pid, :normal, 1_000)
  catch
    :exit, _reason -> :ok
  end

  defp task_supervisor_name, do: AnubisRegistry.task_supervisor_name(AnubisServer)
  defp session_name, do: AnubisRegistry.stdio_session_name(AnubisServer)
  defp transport_name, do: AnubisRegistry.transport_name(AnubisServer, :stdio)

  defp help do
    String.trim_trailing("""
    Usage: codex-loops-mcp --stdio

    Runs the Codex Loops Anubis MCP server over stdio.

    Options:
      --stdio   Start the MCP stdio server.
      --version Show the Codex Loops package version.
      --help    Show this help.
      -h        Show this help.
    """)
  end
end
