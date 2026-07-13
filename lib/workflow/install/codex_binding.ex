defmodule Workflow.Install.CodexBinding do
  @moduledoc """
  Persists and revalidates the exact Codex executable selected at installation.

  Paths remain lexical: an explicitly selected mise/asdf shim stays a shim. The
  exact `codex --version` output is checked again before the scheduler opens its
  long-lived app-server Port.
  """

  import Bitwise, only: [band: 2]

  alias Workflow.Install.Command
  alias Workflow.Install.Error

  @default_timeout 5_000
  @filename "codex-binding.json"

  @enforce_keys [:path, :version]
  defstruct [:path, :version]

  @type t :: %__MODULE__{path: String.t(), version: String.t()}
  @type result(value) :: {:ok, value} | {:error, Error.t()}

  @spec path(keyword()) :: result(String.t())
  def path(opts \\ []) do
    configured =
      Keyword.get(opts, :binding_path) ||
        System.get_env("CODEX_LOOPS_BINDING_PATH")

    case configured do
      path when is_binary(path) and path != "" ->
        require_absolute(path)

      nil ->
        with {:ok, home} <- home(opts) do
          {:ok, Path.join([home, ".codex", "workflows", @filename])}
        end

      _invalid ->
        {:error, Error.new(2, "binding_path_invalid", "The Codex binding path must be an absolute path.")}
    end
  end

  @spec probe(Path.t(), keyword()) :: result(t())
  def probe(path, opts \\ []) do
    path = to_string(path)

    with :ok <- validate_executable(path),
         {:ok, output} <- run_version(path, opts),
         {:ok, version} <- validate_version(output) do
      {:ok, %__MODULE__{path: path, version: version}}
    end
  end

  @spec read(keyword()) :: result(t())
  def read(opts \\ []) do
    with {:ok, path} <- path(opts),
         {:ok, bytes} <- read_file(path) do
      decode(bytes, path)
    end
  end

  @spec read_optional(keyword()) :: result(t() | nil)
  def read_optional(opts \\ []) do
    with {:ok, path} <- path(opts) do
      case File.read(path) do
        {:ok, bytes} -> decode(bytes, path)
        {:error, :enoent} -> {:ok, nil}
        {:error, reason} -> {:error, binding_read_error(path, reason)}
      end
    end
  end

  @spec persist(t(), keyword()) :: :ok | {:error, Error.t()}
  def persist(%__MODULE__{} = binding, opts \\ []) do
    with {:ok, path} <- path(opts),
         {:ok, bytes} <- serialized(binding) do
      write_atomic(path, bytes)
    end
  end

  @spec serialized(t()) :: result(binary())
  def serialized(%__MODULE__{} = binding) do
    with :ok <- validate_binding(binding) do
      {:ok,
       %{"path" => binding.path, "version" => binding.version}
       |> Jason.encode_to_iodata!(pretty: true)
       |> IO.iodata_to_binary()}
    end
  end

  @spec verify(t(), keyword()) :: result(t())
  def verify(%__MODULE__{} = expected, opts \\ []) do
    case probe(expected.path, opts) do
      {:ok, ^expected} ->
        {:ok, expected}

      {:ok, current} ->
        {:error,
         Error.new(
           3,
           "codex_binding_changed",
           "The installed Codex command no longer matches its recorded version.",
           details: %{
             "path" => expected.path,
             "expected_version" => expected.version,
             "current_version" => current.version
           }
         )}

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  @spec load_and_verify(keyword()) :: result(t())
  def load_and_verify(opts \\ []) do
    with {:ok, binding} <- read(opts), do: verify(binding, opts)
  end

  @doc "Returns the direct app-server command after exact-version verification."
  @spec command(keyword()) :: result({String.t(), []})
  def command(opts \\ []) do
    with {:ok, binding} <- load_and_verify(opts), do: {:ok, {binding.path, []}}
  end

  @spec restore(binary() | nil, keyword()) :: :ok | {:error, Error.t()}
  def restore(previous, opts \\ []) do
    with {:ok, path} <- path(opts) do
      case previous do
        nil ->
          case File.rm(path) do
            :ok -> :ok
            {:error, :enoent} -> :ok
            {:error, reason} -> {:error, binding_write_error(path, reason)}
          end

        bytes when is_binary(bytes) ->
          write_atomic(path, bytes)
      end
    end
  end

  @spec restore_if_current(binary() | nil, binary(), keyword()) :: :ok | {:error, Error.t()}
  def restore_if_current(previous, installed, opts \\ []) when is_binary(installed) do
    with {:ok, current} <- snapshot(opts) do
      cond do
        current == previous ->
          :ok

        current == installed ->
          restore(previous, opts)

        true ->
          {:error,
           Error.new(
             4,
             "codex_binding_rollback_conflict",
             "The Codex binding changed after installation and was not overwritten during rollback."
           )}
      end
    end
  end

  @spec snapshot(keyword()) :: result(binary() | nil)
  def snapshot(opts \\ []) do
    with {:ok, path} <- path(opts) do
      case File.read(path) do
        {:ok, bytes} -> {:ok, bytes}
        {:error, :enoent} -> {:ok, nil}
        {:error, reason} -> {:error, binding_read_error(path, reason)}
      end
    end
  end

  defp home(opts) do
    case Keyword.get(opts, :home) || System.get_env("HOME") do
      home when is_binary(home) and home != "" -> require_absolute(home)
      _ -> {:error, Error.new(3, "home_unavailable", "A user home directory is required.")}
    end
  end

  defp require_absolute(path) do
    if Path.type(path) == :absolute and safe_text?(path) do
      {:ok, path}
    else
      {:error,
       Error.new(2, "binding_path_invalid", "The Codex binding path must be absolute and contain no control characters.")}
    end
  end

  defp validate_executable(path) do
    with :absolute <- Path.type(path),
         true <- safe_text?(path),
         {:ok, %File.Stat{type: :regular, mode: mode}} <- File.stat(path),
         true <- band(mode, 0o111) != 0 do
      :ok
    else
      _ ->
        {:error,
         Error.new(3, "codex_binding_invalid", "The selected Codex command is not an absolute executable file.",
           details: %{"path" => path}
         )}
    end
  end

  defp run_version(path, opts) do
    runner = Keyword.get(opts, :command_runner, &Command.run/3)
    timeout = Keyword.get(opts, :command_timeout, @default_timeout)

    case runner.(path, ["--version"], timeout: timeout, max_output_bytes: 16_384) do
      {:ok, %{status: 0, output: output}} ->
        {:ok, output}

      {:ok, %{status: status, output: output}} ->
        {:error,
         Error.new(3, "codex_probe_failed", "The selected Codex command could not report its version.",
           details: %{"path" => path, "status" => status, "output" => String.trim(output)}
         )}

      {:error, reason} ->
        {:error,
         Error.new(3, "codex_probe_failed", "The selected Codex command could not report its version.",
           details: %{"path" => path, "reason" => inspect(reason)}
         )}
    end
  end

  defp validate_version(output) do
    version = String.trim(output)

    if valid_version?(version) do
      {:ok, version}
    else
      {:error,
       Error.new(3, "codex_version_invalid", "The selected command returned an invalid Codex version.",
         details: %{"output" => version}
       )}
    end
  end

  defp read_file(path) do
    case File.read(path) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, reason} -> {:error, binding_read_error(path, reason)}
    end
  end

  defp decode(bytes, path) do
    case Jason.decode(bytes) do
      {:ok, %{"path" => stored_path, "version" => version} = value}
      when map_size(value) == 2 and is_binary(stored_path) and is_binary(version) ->
        binding = %__MODULE__{path: stored_path, version: version}

        case validate_binding(binding) do
          :ok -> {:ok, binding}
          {:error, _error} -> {:error, binding_decode_error(path)}
        end

      _ ->
        {:error, binding_decode_error(path)}
    end
  end

  defp validate_binding(%__MODULE__{path: path, version: version}) do
    if Path.type(path) == :absolute and safe_text?(path) and valid_version?(version) do
      :ok
    else
      {:error, Error.new(3, "codex_binding_invalid", "The persisted Codex binding is invalid.")}
    end
  end

  defp valid_version?(version) do
    String.starts_with?(version, "codex-cli ") and
      version |> String.replace_prefix("codex-cli ", "") |> String.trim() != "" and
      safe_text?(version)
  end

  defp safe_text?(value) when is_binary(value) do
    String.valid?(value) and
      value
      |> String.to_charlist()
      |> Enum.all?(fn codepoint -> codepoint >= 0x20 and codepoint != 0x7F end)
  end

  defp write_atomic(path, contents) do
    parent = Path.dirname(path)
    temporary = path <> ".#{System.unique_integer([:positive])}.tmp"

    with :ok <- File.mkdir_p(parent),
         :ok <- File.write(temporary, contents, [:write, :exclusive]),
         :ok <- File.chmod(temporary, 0o600),
         :ok <- File.rename(temporary, path) do
      :ok
    else
      {:error, reason} ->
        File.rm(temporary)
        {:error, binding_write_error(path, reason)}
    end
  end

  defp binding_read_error(path, reason) do
    Error.new(3, "codex_binding_unavailable", "The persisted Codex binding could not be read.",
      details: %{"path" => path, "reason" => inspect(reason)}
    )
  end

  defp binding_decode_error(path) do
    Error.new(3, "codex_binding_invalid", "The persisted Codex binding is invalid.", details: %{"path" => path})
  end

  defp binding_write_error(path, reason) do
    Error.new(6, "codex_binding_write_failed", "The Codex binding could not be committed.",
      details: %{"path" => path, "reason" => inspect(reason)}
    )
  end
end
