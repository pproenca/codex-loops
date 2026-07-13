defmodule Workflow.Install.Skill do
  @moduledoc false

  alias Workflow.Install.Change
  alias Workflow.Install.Error
  alias Workflow.PackageVersion

  @marker ".codex-loops-version"

  defmodule Config do
    @moduledoc false
    @enforce_keys [:source, :destination]
    defstruct @enforce_keys

    @type t :: %__MODULE__{source: String.t(), destination: String.t()}
  end

  @type state :: :current | :missing | :drifted
  @type result(value) :: {:ok, value} | {:error, Error.t()}

  @spec config(keyword()) :: result(Config.t())
  def config(opts \\ []) do
    source = Keyword.get(opts, :skill_source) || System.get_env("CODEX_LOOPS_SKILL_SOURCE")

    with source when is_binary(source) and source != "" <- source,
         :absolute <- Path.type(source),
         true <- File.regular?(Path.join(source, "SKILL.md")),
         {:ok, home} <- home(opts),
         destination =
           Keyword.get(opts, :skill_path) ||
             System.get_env("CODEX_LOOPS_SKILL_PATH") ||
             Path.join([home, ".agents", "skills", "codex-loops"]),
         :absolute <- Path.type(destination),
         :ok <- validate_tree(source) do
      {:ok, %Config{source: source, destination: destination}}
    else
      {:error, %Error{} = error} ->
        {:error, error}

      _ ->
        {:error,
         Error.new(3, "skill_source_invalid", "The packaged Codex Loops skill is missing or invalid.",
           details: %{"source" => source}
         )}
    end
  end

  @spec inspect_state(Config.t()) :: result(state())
  def inspect_state(%Config{} = config) do
    case File.lstat(config.destination) do
      {:error, :enoent} ->
        {:ok, :missing}

      {:ok, %File.Stat{type: :directory}} ->
        inspect_directory(config)

      {:ok, _stat} ->
        {:error,
         Error.new(4, "skill_destination_conflict", "The Codex Loops skill destination is not a managed directory.",
           details: %{"path" => config.destination}
         )}

      {:error, reason} ->
        {:error, file_error("skill_read_failed", config.destination, reason)}
    end
  end

  @spec install(Config.t(), keyword()) :: result(Change.t())
  def install(%Config{} = config, opts \\ []) do
    parent = Path.dirname(config.destination)
    suffix = Integer.to_string(System.unique_integer([:positive]))
    stage = config.destination <> ".stage." <> suffix
    backup = config.destination <> ".backup." <> suffix

    with :ok <- File.mkdir_p(parent),
         :ok <- ensure_destination_owned(config.destination),
         {:ok, previous?} <- move_previous(config.destination, backup),
         :ok <- ensure_backup_owned(backup, previous?),
         {:ok, previous_snapshot} <- previous_snapshot(backup, previous?),
         :ok <- copy_tree(config.source, stage),
         :ok <- File.write(Path.join(stage, @marker), PackageVersion.version() <> "\n", [:write, :exclusive]),
         :ok <- File.rename(stage, config.destination) do
      rollback = fn -> restore(config, backup, previous?, previous_snapshot) end
      commit = fn -> remove_backup(backup, previous?, opts) end
      {:ok, Change.new("skill", rollback, commit)}
    else
      {:error, %Error{} = error} ->
        failed_install(error, config.destination, stage, backup)

      {:error, reason} ->
        error = file_error("skill_install_failed", config.destination, reason)
        failed_install(error, config.destination, stage, backup)
    end
  end

  defp inspect_directory(config) do
    marker_path = Path.join(config.destination, @marker)

    case File.read(marker_path) do
      {:ok, marker} ->
        with :ok <- validate_tree(config.destination),
             {:ok, source} <- tree_contents(config.source),
             {:ok, destination} <- tree_contents(config.destination, [@marker]) do
          if String.trim(marker) == PackageVersion.version() and source == destination do
            {:ok, :current}
          else
            {:ok, :drifted}
          end
        end

      {:error, :enoent} ->
        {:error,
         Error.new(4, "skill_destination_conflict", "The existing skill directory is not managed by Codex Loops.",
           details: %{"path" => config.destination}
         )}

      {:error, reason} ->
        {:error, file_error("skill_read_failed", marker_path, reason)}
    end
  end

  defp validate_tree(root) do
    with {:ok, paths} <- tree_paths(root) do
      Enum.reduce_while(paths, :ok, fn path, :ok ->
        case File.lstat(path) do
          {:ok, %File.Stat{type: type}} when type in [:regular, :directory] ->
            {:cont, :ok}

          {:ok, %File.Stat{type: type}} ->
            {:halt,
             {:error,
              Error.new(4, "skill_tree_invalid", "The skill tree contains an unsupported file type.",
                details: %{"path" => path, "type" => to_string(type)}
              )}}

          {:error, reason} ->
            {:halt, {:error, file_error("skill_read_failed", path, reason)}}
        end
      end)
    end
  end

  defp tree_contents(root, excluded \\ []) do
    with {:ok, paths} <- tree_paths(root) do
      Enum.reduce_while(paths, {:ok, %{}}, fn path, {:ok, contents} ->
        relative = Path.relative_to(path, root)

        cond do
          relative == "." or relative in excluded ->
            {:cont, {:ok, contents}}

          File.dir?(path) ->
            {:cont, {:ok, Map.put(contents, relative, :directory)}}

          true ->
            with {:ok, %File.Stat{type: :regular, mode: mode}} <- File.lstat(path),
                 {:ok, bytes} <- File.read(path) do
              {:cont, {:ok, Map.put(contents, relative, {:file, bytes, Bitwise.band(mode, 0o777)})}}
            else
              {:ok, %File.Stat{type: type}} ->
                {:halt,
                 {:error,
                  Error.new(4, "skill_tree_invalid", "The skill tree contains an unsupported file type.",
                    details: %{"path" => path, "type" => to_string(type)}
                  )}}

              {:error, reason} ->
                {:halt, {:error, file_error("skill_read_failed", path, reason)}}
            end
        end
      end)
    end
  end

  defp tree_paths(root) do
    with {:ok, paths} <- collect_paths(root, []) do
      {:ok, paths |> Enum.uniq() |> Enum.sort()}
    end
  end

  defp collect_paths(path, paths) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} ->
        case File.ls(path) do
          {:ok, entries} ->
            Enum.reduce_while(entries, {:ok, [path | paths]}, fn entry, {:ok, collected} ->
              case collect_paths(Path.join(path, entry), collected) do
                {:ok, next} -> {:cont, {:ok, next}}
                {:error, %Error{} = error} -> {:halt, {:error, error}}
              end
            end)

          {:error, reason} ->
            {:error, file_error("skill_read_failed", path, reason)}
        end

      {:ok, _stat} ->
        {:ok, [path | paths]}

      {:error, reason} ->
        {:error, file_error("skill_read_failed", path, reason)}
    end
  end

  defp copy_tree(source, destination) do
    with :ok <- File.mkdir(destination),
         {:ok, entries} <- File.ls(source) do
      Enum.reduce_while(entries, :ok, fn entry, :ok ->
        from = Path.join(source, entry)
        to = Path.join(destination, entry)

        result =
          case File.lstat(from) do
            {:ok, %File.Stat{type: :directory}} -> copy_tree(from, to)
            {:ok, %File.Stat{type: :regular, mode: mode}} -> copy_file(from, to, mode)
            {:ok, %File.Stat{type: type}} -> {:error, {:unsupported_type, type}}
            {:error, reason} -> {:error, reason}
          end

        case result do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end
  end

  defp copy_file(source, destination, mode) do
    with {:ok, _bytes} <- File.copy(source, destination), do: File.chmod(destination, Bitwise.band(mode, 0o777))
  end

  defp move_previous(destination, backup) do
    case File.lstat(destination) do
      {:error, :enoent} -> {:ok, false}
      {:ok, %File.Stat{type: :directory}} -> destination |> File.rename(backup) |> normalize_move()
      {:ok, _stat} -> {:error, :destination_conflict}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_move(:ok), do: {:ok, true}
  defp normalize_move({:error, reason}), do: {:error, reason}

  defp ensure_destination_owned(destination) do
    case File.lstat(destination) do
      {:error, :enoent} -> :ok
      {:ok, %File.Stat{type: :directory}} -> ensure_managed_directory(destination)
      {:ok, _stat} -> {:error, :destination_conflict}
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_backup_owned(_backup, false), do: :ok
  defp ensure_backup_owned(backup, true), do: ensure_managed_directory(backup)

  defp ensure_managed_directory(path) do
    case File.read(Path.join(path, @marker)) do
      {:ok, _marker} ->
        validate_tree(path)

      {:error, :enoent} ->
        {:error,
         Error.new(4, "skill_destination_conflict", "The existing skill directory is not managed by Codex Loops.",
           details: %{"path" => path}
         )}

      {:error, reason} ->
        {:error, file_error("skill_read_failed", path, reason)}
    end
  end

  defp previous_snapshot(_backup, false), do: {:ok, nil}
  defp previous_snapshot(backup, true), do: tree_contents(backup)

  defp restore(config, backup, previous?, previous_snapshot) do
    case File.lstat(config.destination) do
      {:error, :enoent} ->
        if previous?, do: {:error, :installed_skill_removed}, else: :ok

      {:ok, %File.Stat{type: :directory}} ->
        cond do
          previous? and tree_matches?(config.destination, previous_snapshot) ->
            :ok

          installed_tree?(config) ->
            restore_installed_tree(config.destination, backup, previous?, previous_snapshot)

          true ->
            {:error, :installed_skill_changed}
        end

      {:ok, _stat} ->
        {:error, :installed_skill_replaced}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp installed_tree?(config), do: inspect_state(config) == {:ok, :current}

  defp tree_matches?(path, expected) do
    with :ok <- validate_tree(path),
         {:ok, actual} <- tree_contents(path) do
      actual == expected
    else
      _missing_or_changed -> false
    end
  end

  defp restore_installed_tree(destination, _backup, false, _previous_snapshot) do
    case File.rm_rf(destination) do
      {:ok, _removed} -> :ok
      {:error, reason, path} -> {:error, {reason, path}}
    end
  end

  defp restore_installed_tree(destination, backup, true, previous_snapshot) do
    if tree_matches?(backup, previous_snapshot) do
      case File.rm_rf(destination) do
        {:ok, _removed} -> File.rename(backup, destination)
        {:error, reason, path} -> {:error, {reason, path}}
      end
    else
      {:error, :skill_backup_changed}
    end
  end

  defp remove_backup(_backup, false, _opts), do: :ok

  defp remove_backup(backup, true, opts) do
    cleanup = Keyword.get(opts, :skill_backup_cleanup, &File.rm_rf/1)

    case cleanup.(backup) do
      {:ok, _files} -> :ok
      {:error, reason, _path} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp failed_install(error, destination, stage, backup) do
    case cleanup_failed_install(destination, stage, backup) do
      :ok ->
        {:error, error}

      {:error, reason} ->
        {:error,
         Error.new(6, "skill_rollback_failed", "The failed skill update could not restore the prior directory.",
           details: %{"install_error" => Error.to_map(error), "backup" => backup, "reason" => inspect(reason)},
           changed: true
         )}
    end
  end

  defp cleanup_failed_install(destination, stage, backup) do
    case File.rm_rf(stage) do
      {:ok, _removed} ->
        case File.lstat(backup) do
          {:error, :enoent} ->
            :ok

          {:ok, %File.Stat{type: :directory}} ->
            case File.lstat(destination) do
              {:error, :enoent} -> File.rename(backup, destination)
              {:ok, _stat} -> {:error, :destination_reappeared}
              {:error, reason} -> {:error, reason}
            end

          {:ok, _stat} ->
            {:error, :invalid_backup}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason, path} ->
        {:error, {reason, path}}
    end
  end

  defp home(opts) do
    case Keyword.get(opts, :home) || System.get_env("HOME") do
      home when is_binary(home) and home != "" ->
        if Path.type(home) == :absolute,
          do: {:ok, home},
          else: {:error, Error.new(3, "home_unavailable", "A user home directory is required.")}

      _ ->
        {:error, Error.new(3, "home_unavailable", "A user home directory is required.")}
    end
  end

  defp file_error(code, path, reason) do
    Error.new(6, code, "The Codex Loops skill could not be updated.",
      details: %{"path" => path, "reason" => inspect(reason)}
    )
  end
end
