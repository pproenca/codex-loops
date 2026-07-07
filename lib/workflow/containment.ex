defmodule Workflow.Containment do
  @moduledoc """
  The **containment boundary**: the single place a workflow reaches an external
  OS process. Keeping every spawn behind this seam is what lets the interpreter
  core stay deterministic and I/O-free — no subprocess call leaks into the folds,
  the compiler, or the tree.

  `run_turn/2` spawns the injected command as a **one-shot** child, feeds it the
  given `stdin` bytes, streams the child's stdout until it exits, and returns the
  raw stdout on a clean (`0`) exit. The `stdin` is delivered by redirecting the
  child's standard input from a temporary file, so the child always sees a normal
  EOF-terminated input and never blocks on an open, never-closed pipe — a subtlety
  that matters because a duplex Erlang port cannot half-close stdin.

  Containment knows nothing about the *wire format* of the bytes it moves: the
  caller (the provider) owns encoding the request and decoding the response. That
  keeps this layer a pure process seam with no protocol claims of its own. A
  non-zero exit or a stall past `:timeout` is surfaced as `{:error, _}` so the
  caller can crash the run rather than journal a phantom result.

  The command is injected as `command: {executable, args}` — the seam a test uses
  to point at a hermetic stub and the seam the provider uses to point at the real
  `codex` binary. `:timeout` defaults to `:infinity`: an agent turn has no fixed
  deadline, so the live path imposes none unless a caller opts in.
  """

  @default_timeout :infinity

  @doc """
  Run one contained, one-shot turn. Spawns `opts[:command]` (a `{path, args}`
  tuple), pipes `stdin` to it, and returns `{:ok, stdout}` on a clean exit, or
  `{:error, reason}` for a non-zero exit or a timeout.
  """
  @spec run_turn(iodata(), keyword()) :: {:ok, binary()} | {:error, term()}
  def run_turn(stdin, opts) do
    {path, args} = Keyword.fetch!(opts, :command)
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    stdin_file = write_stdin(stdin)

    try do
      port = Port.open({:spawn, shell_command(path, args, stdin_file)}, [:binary, :exit_status])
      collect(port, "", "", timeout, Keyword.get(opts, :on_line))
    after
      File.rm(stdin_file)
    end
  end

  # Accumulate stdout until the child exits; the OS/port guarantees every `:data`
  # arrives before `:exit_status`, so the buffer is complete at exit.
  defp collect(port, buffer, line_buffer, timeout, on_line) do
    receive do
      {^port, {:data, data}} ->
        collect(
          port,
          buffer <> data,
          observe_lines(line_buffer <> data, on_line),
          timeout,
          on_line
        )

      {^port, {:exit_status, 0}} ->
        flush_line(line_buffer, on_line)
        {:ok, buffer}

      {^port, {:exit_status, status}} ->
        flush_line(line_buffer, on_line)
        {:error, {:backend_exit, status, buffer}}
    after
      timeout ->
        Port.close(port)
        {:error, :timeout}
    end
  end

  defp observe_lines(_data, nil), do: ""

  defp observe_lines(data, on_line) do
    parts = String.split(data, "\n")
    {complete, [tail]} = Enum.split(parts, length(parts) - 1)
    Enum.each(complete, &emit_line(&1, on_line))
    tail
  end

  defp flush_line("", _on_line), do: :ok
  defp flush_line(_line, nil), do: :ok
  defp flush_line(line, on_line), do: emit_line(line, on_line)

  defp emit_line("", _on_line), do: :ok
  defp emit_line(line, on_line), do: on_line.(line)

  defp write_stdin(stdin) do
    path = Path.join(System.tmp_dir!(), "codex_turn_#{System.unique_integer([:positive])}.stdin")
    File.write!(path, stdin)
    path
  end

  # Build a `/bin/sh -c` command that runs the executable with its args and reads
  # stdin from `stdin_file`. Every token is single-quoted (with embedded quotes
  # escaped) so nothing in a path or arg is ever interpreted by the shell; only the
  # `<` redirect is a shell operator.
  defp shell_command(path, args, stdin_file) do
    Enum.map_join([path | args], " ", &shell_quote/1) <> " < " <> shell_quote(stdin_file)
  end

  defp shell_quote(token), do: "'" <> String.replace(token, "'", "'\\''") <> "'"
end
