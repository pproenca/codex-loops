defmodule Workflow.MCP.ApplicationEntrypoint do
  @moduledoc false

  alias Workflow.MCP.AnubisStdio

  require Logger

  @spec run :: no_return()
  def run do
    Logger.configure(level: :emergency)

    case AnubisStdio.main() do
      :ok ->
        System.halt(0)

      {:error, status} when is_integer(status) ->
        System.halt(status)

      {:error, reason} ->
        IO.puts(:stderr, "codex-loops-mcp failed: #{inspect(reason)}")
        System.halt(1)
    end
  end
end
