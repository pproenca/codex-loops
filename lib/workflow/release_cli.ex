defmodule Workflow.ReleaseCLI do
  @moduledoc """
  Release wrapper entry point for the packaged `agent-loops` command.

  Mix release `eval` receives an expression, not a normal argv vector. The shell
  overlay therefore encodes the original argv as a base64, nul-delimited binary in
  `AGENT_LOOPS_ARGV_B64`; this module decodes it and hands the exact argv to the
  normal `Workflow.CLI.exec/1` seam.
  """

  @argv_env "AGENT_LOOPS_ARGV_B64"

  @doc "Run the packaged CLI from the release wrapper environment and halt."
  @spec main_from_env() :: no_return()
  def main_from_env do
    @argv_env
    |> System.get_env()
    |> decode_argv()
    |> Workflow.CLI.exec()
    |> System.halt()
  end

  @doc "Decode the release wrapper's base64 nul-delimited argv payload."
  @spec decode_argv(String.t() | nil) :: [String.t()]
  def decode_argv(nil), do: []
  def decode_argv(""), do: []

  def decode_argv(encoded) when is_binary(encoded) do
    with {:ok, binary} <- Base.decode64(encoded),
         {:ok, argv} <- split_argv(binary) do
      argv
    else
      :error -> raise ArgumentError, "invalid #{@argv_env}: expected base64"
      {:error, reason} -> raise ArgumentError, "invalid #{@argv_env}: #{reason}"
    end
  end

  defp split_argv(<<>>), do: {:ok, []}

  defp split_argv(binary) do
    case :binary.split(binary, <<0>>, [:global]) |> Enum.reverse() do
      ["" | rev] -> {:ok, Enum.reverse(rev)}
      _parts -> {:error, "payload must end with a nul terminator"}
    end
  end
end
