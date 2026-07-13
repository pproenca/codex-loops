defmodule Workflow.Containment do
  @moduledoc """
  The **containment boundary**: the single place a workflow reaches an external
  OS process. Keeping every spawn behind this seam is what lets the interpreter
  core stay deterministic and I/O-free — no subprocess call leaks into the folds,
  the compiler, or the tree.

  `run_turn/2` spawns the injected command as a **one-shot** child, feeds it the
  given `stdin` bytes, streams the child's stdout until it exits, and returns the
  bounded stdout on a clean (`0`) exit. Stderr is discarded so an untrusted child
  cannot fill an unbounded side file or corrupt a JSONL stdout protocol. The
  `stdin` is delivered by redirecting the child's standard
  input from a temporary file, so the child always sees a normal EOF-terminated
  input and never blocks on an open, never-closed pipe — a subtlety that matters
  because a duplex Erlang port cannot half-close stdin.

  Containment knows nothing about the *wire format* of the bytes it moves: the
  caller (the provider) owns encoding the request and decoding the response. That
  keeps this layer a pure process seam with no protocol claims of its own. A
  non-zero exit, oversized stream, or stall past `:timeout` is surfaced as an
  error so the
  caller can crash the run rather than journal a phantom result.

  The command is injected as `command: {executable, args}` — the seam a test uses
  to point at a hermetic stub and the seam the provider uses to point at the real
  `codex` binary. Input, output, and elapsed time all have system-owned bounds.
  """

  @default_timeout 30 * 60 * 1_000
  @max_input_bytes 16 * 1024 * 1024
  @max_output_bytes 16 * 1024 * 1024

  @doc """
  Run one contained, one-shot turn. Spawns `opts[:command]` (a `{path, args}`
  tuple), pipes `stdin` to it, and returns `{:ok, stdout}` on a clean exit, or
  `{:error, reason}` for a non-zero exit or a timeout.
  """
  @spec run_turn(iodata(), keyword()) ::
          {:ok, binary(), term()}
          | {:error, :timeout | :input_limit | :output_limit | {:backend_exit, integer(), binary()}, term()}
  def run_turn(stdin, opts) do
    {path, args} = Keyword.fetch!(opts, :command)
    timeout = bounded_option(opts, :timeout, @default_timeout)
    max_input_bytes = bounded_option(opts, :max_input_bytes, @max_input_bytes)
    max_output_bytes = bounded_option(opts, :max_output_bytes, @max_output_bytes)
    line_acc = Keyword.get(opts, :line_acc)
    stdin_file = temp_path("codex_turn", ".stdin")

    if IO.iodata_length(stdin) > max_input_bytes do
      {:error, :input_limit, line_acc}
    else
      write_private!(stdin_file, stdin)

      try do
        port =
          Port.open({:spawn, shell_command(path, args, stdin_file)}, [
            :binary,
            :exit_status
          ])

        deadline = System.monotonic_time(:millisecond) + timeout

        collect(
          port,
          [],
          0,
          [],
          deadline,
          max_output_bytes,
          Keyword.get(opts, :on_line),
          line_acc
        )
      after
        File.rm(stdin_file)
      end
    end
  end

  # Accumulate stdout until the child exits; the OS/port guarantees every `:data`
  # arrives before `:exit_status`, so the buffer is complete at exit.
  defp collect(port, chunks, size, line_buffer, deadline, max_output_bytes, on_line, line_acc) do
    receive do
      {^port, {:data, data}} ->
        next_size = size + byte_size(data)

        if next_size > max_output_bytes do
          Port.close(port)
          {:error, :output_limit, line_acc}
        else
          {line_buffer, line_acc} = observe_lines(line_buffer, data, on_line, line_acc)

          collect(
            port,
            [data | chunks],
            next_size,
            line_buffer,
            deadline,
            max_output_bytes,
            on_line,
            line_acc
          )
        end

      {^port, {:exit_status, 0}} ->
        line_acc = flush_line(line_buffer, on_line, line_acc)
        {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary(), line_acc}

      {^port, {:exit_status, status}} ->
        line_acc = flush_line(line_buffer, on_line, line_acc)
        output = chunks |> Enum.reverse() |> IO.iodata_to_binary()
        {:error, {:backend_exit, status, output}, line_acc}
    after
      remaining(deadline) ->
        Port.close(port)
        {:error, :timeout, line_acc}
    end
  end

  defp observe_lines(_line_buffer, _data, nil, line_acc), do: {[], line_acc}

  defp observe_lines(line_buffer, data, on_line, line_acc) do
    case :binary.split(data, "\n", [:global]) do
      [partial] ->
        {[line_buffer, partial], line_acc}

      [head | rest] ->
        {tail, complete} = List.pop_at(rest, -1)
        line_acc = emit_line(IO.iodata_to_binary([line_buffer, head]), on_line, line_acc)
        line_acc = Enum.reduce(complete, line_acc, &emit_line(&1, on_line, &2))
        {:binary.copy(tail), line_acc}
    end
  end

  defp flush_line([], _on_line, line_acc), do: line_acc
  defp flush_line("", _on_line, line_acc), do: line_acc
  defp flush_line(_line, nil, line_acc), do: line_acc

  defp flush_line(line, on_line, line_acc), do: line |> IO.iodata_to_binary() |> emit_line(on_line, line_acc)

  defp emit_line("", _on_line, line_acc), do: line_acc
  defp emit_line(line, on_line, line_acc), do: on_line.(line_acc, line)

  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

  defp bounded_option(opts, key, system_max) do
    case Keyword.get(opts, key, system_max) do
      value when is_integer(value) and value > 0 -> min(value, system_max)
      value -> raise ArgumentError, "#{key} must be a positive integer, got: #{inspect(value)}"
    end
  end

  defp write_private!(path, contents) do
    {:ok, file} = File.open(path, [:write, :exclusive, :binary])

    try do
      File.chmod!(path, 0o600)
      :ok = IO.binwrite(file, contents)
    after
      File.close(file)
    end
  end

  defp temp_path(prefix, suffix) do
    Path.join(System.tmp_dir!(), "#{prefix}_#{System.unique_integer([:positive])}#{suffix}")
  end

  # Build a `/bin/sh -c` command that runs the executable with its args and reads
  # stdin from `stdin_file` while discarding stderr. Every token is
  # single-quoted (with embedded quotes escaped) so nothing in a path or arg is
  # ever interpreted by the shell; only the redirects are shell operators.
  defp shell_command(path, args, stdin_file) do
    Enum.map_join([path | args], " ", &shell_quote/1) <>
      " < " <> shell_quote(stdin_file) <> " 2> /dev/null"
  end

  defp shell_quote(token), do: "'" <> String.replace(token, "'", "'\\''") <> "'"
end
