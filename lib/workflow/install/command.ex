defmodule Workflow.Install.Command do
  @moduledoc false

  @default_timeout 5_000
  @default_max_output_bytes 1_048_576

  @type result :: {:ok, %{status: non_neg_integer(), output: binary()}} | {:error, term()}

  @spec run(String.t(), [String.t()], keyword()) :: result()
  def run(program, args, opts \\ []) when is_binary(program) and is_list(args) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    max_output_bytes = Keyword.get(opts, :max_output_bytes, @default_max_output_bytes)

    port_opts = [
      :binary,
      :exit_status,
      :use_stdio,
      :stderr_to_stdout,
      args: Enum.map(args, &String.to_charlist/1)
    ]

    port_opts =
      case Keyword.get(opts, :cd) do
        nil -> port_opts
        path -> [{:cd, String.to_charlist(path)} | port_opts]
      end

    try do
      program
      |> String.to_charlist()
      |> then(&Port.open({:spawn_executable, &1}, port_opts))
      |> collect([], 0, deadline(timeout), max_output_bytes)
    rescue
      error in [ArgumentError, ErlangError] -> {:error, Exception.message(error)}
    end
  end

  defp collect(port, output, size, deadline, max_output_bytes) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      close(port)
      {:error, :timeout}
    else
      receive do
        {^port, {:data, data}} when size + byte_size(data) <= max_output_bytes ->
          collect(port, [data | output], size + byte_size(data), deadline, max_output_bytes)

        {^port, {:data, _data}} ->
          close(port)
          {:error, :output_limit}

        {^port, {:exit_status, status}} ->
          {:ok, %{status: status, output: output |> Enum.reverse() |> IO.iodata_to_binary()}}
      after
        remaining ->
          close(port)
          {:error, :timeout}
      end
    end
  end

  defp deadline(timeout) when is_integer(timeout) and timeout > 0 do
    System.monotonic_time(:millisecond) + timeout
  end

  defp close(port) do
    Port.close(port)
  catch
    :error, :badarg -> :ok
  end
end
