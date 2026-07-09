defmodule Workflow.MCP.BurritoEnvironment do
  @moduledoc false

  @spec bootstrap :: :ok
  def bootstrap do
    infer_plugin_root()
    :ok
  end

  @spec argv :: [String.t()]
  def argv do
    if burrito?() do
      :init.get_plain_arguments() |> Enum.map(&to_string/1)
    else
      System.argv()
    end
  end

  @spec mcp_entrypoint? :: boolean()
  def mcp_entrypoint? do
    System.get_env("CODEX_LOOPS_ENTRYPOINT") == "mcp" or mcp_burrito_binary?()
  end

  defp infer_plugin_root do
    cond do
      present?(System.get_env("CODEX_LOOPS_PLUGIN_ROOT")) ->
        :ok

      present?(System.get_env("CODEX_LOOPS_SCHEDULER_BIN")) ->
        :ok

      bin_path = System.get_env("__BURRITO_BIN_PATH") ->
        System.put_env("CODEX_LOOPS_PLUGIN_ROOT", plugin_root_from_bin(bin_path))

      true ->
        :ok
    end
  end

  defp plugin_root_from_bin(bin_path) do
    bin_path
    |> Path.expand()
    |> Path.dirname()
    |> case do
      mcp_dir ->
        if Path.basename(mcp_dir) == "mcp" do
          Path.dirname(mcp_dir)
        else
          mcp_dir
        end
    end
  end

  defp burrito? do
    present?(System.get_env("__BURRITO")) or present?(System.get_env("__BURRITO_BIN_PATH"))
  end

  defp mcp_burrito_binary? do
    case System.get_env("__BURRITO_BIN_PATH") do
      nil ->
        false

      bin_path ->
        bin_name = bin_path |> Path.expand() |> Path.basename()
        bin_name == "codex-loops-mcp" or String.starts_with?(bin_name, "codex_loops_mcp")
    end
  end

  defp present?(nil), do: false
  defp present?(""), do: false
  defp present?(_value), do: true
end
