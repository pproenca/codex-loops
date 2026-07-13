defmodule Workflow.Install.Lock do
  @moduledoc false

  alias Workflow.Install.Error

  @owner_file "owner.json"
  @reclaim_suffix ".reclaim"

  @spec with_lock(String.t(), keyword(), (-> term())) :: term()
  def with_lock(path, opts, fun) when is_binary(path) and is_function(fun, 0) do
    with :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, token} <- acquire(path, opts) do
      try do
        fun.()
      after
        release(path, token)
      end
    else
      {:error, %Error{} = error} -> {:error, error}
      {:error, reason} -> {:error, lock_error("install_lock_failed", path, reason)}
    end
  end

  defp acquire(path, opts) do
    owner = %{"pid" => Keyword.get(opts, :install_pid, System.pid()), "token" => token()}
    gate = path <> @reclaim_suffix

    with :ok <- validate_owner(owner),
         :ok <- recover_orphan_storages(path, opts),
         :ok <- recover_orphan_storages(gate, opts),
         :ok <- ensure_no_reclaimer(path, opts) do
      case create(path, owner) do
        :ok -> {:ok, owner["token"]}
        {:error, :occupied} -> reclaim(path, owner, opts)
        {:error, reason} -> {:error, lock_error("install_lock_failed", path, reason)}
      end
    end
  end

  defp create(path, owner) do
    storage = storage_path(path, owner["token"])
    staging = storage <> ".prepare"

    result =
      with :ok <- File.mkdir(staging),
           :ok <- File.chmod(staging, 0o700),
           :ok <- File.write(Path.join(staging, @owner_file), Jason.encode!(owner), [:write, :exclusive]),
           :ok <- File.chmod(Path.join(staging, @owner_file), 0o600),
           :ok <- File.rename(staging, storage) do
        case File.ln_s(storage, path) do
          :ok -> :ok
          {:error, :eexist} -> {:error, :occupied}
          {:error, reason} -> {:error, reason}
        end
      end

    if result != :ok do
      File.rm_rf(staging)
      File.rm_rf(storage)
    end

    result
  end

  defp reclaim(path, owner, opts) do
    gate = path <> @reclaim_suffix

    case acquire_reclaim_gate(path, gate, owner, opts, false) do
      :ok ->
        try do
          reclaim_under_gate(path, owner, opts)
        after
          release(gate, owner["token"])
        end

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp acquire_reclaim_gate(path, gate, owner, opts, retried?) do
    case create(gate, owner) do
      :ok ->
        :ok

      {:error, :occupied} when not retried? ->
        with :ok <- ensure_no_reclaimer(path, opts) do
          acquire_reclaim_gate(path, gate, owner, opts, true)
        end

      {:error, :occupied} ->
        {:error, install_in_progress(path, "Another installation is reconciling the installation lock.")}

      {:error, reason} ->
        {:error, lock_error("install_lock_failed", path, reason)}
    end
  end

  defp reclaim_under_gate(path, owner, opts) do
    with {:ok, previous_owner} <- read_validated_owner(path),
         {:ok, alive?} <- process_alive(previous_owner["pid"], opts) do
      if alive? do
        {:error,
         Error.new(4, "install_in_progress", "Another Codex Loops installation is already active.",
           details: %{"path" => path, "pid" => previous_owner["pid"]}
         )}
      else
        replace_stale(path, owner, previous_owner)
      end
    end
  end

  defp replace_stale(path, owner, previous_owner) do
    stale = path <> ".stale." <> owner["token"]

    with {:ok, previous_storage} <- previous_storage(path, previous_owner["token"]),
         :ok <- File.rename(path, stale) do
      result =
        case create(path, owner) do
          :ok ->
            {:ok, owner["token"]}

          {:error, :occupied} ->
            {:error, Error.new(4, "install_in_progress", "Another installation acquired the lock.")}

          {:error, reason} ->
            {:error, lock_error("install_lock_failed", path, reason)}
        end

      cleanup_stale(stale, previous_storage)
      result
    else
      {:error, %Error{} = error} ->
        {:error, error}

      {:error, reason} when reason in [:enoent, :eexist, :enotempty] ->
        {:error, Error.new(4, "install_in_progress", "Another installation changed the installation lock.")}

      {:error, reason} ->
        {:error, lock_error("install_lock_failed", path, reason)}
    end
  end

  defp previous_storage(path, token) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :symlink}} ->
        expected = storage_path(path, token)

        case File.read_link(path) do
          {:ok, ^expected} ->
            case File.lstat(expected) do
              {:ok, %File.Stat{type: :directory}} -> {:ok, expected}
              _missing_or_unsupported -> {:error, invalid_lock(path, "The installation lock owner storage is invalid.")}
            end

          _other ->
            {:error, invalid_lock(path, "The installation lock points outside its owner storage.")}
        end

      {:ok, %File.Stat{type: :directory}} ->
        {:ok, nil}

      {:ok, _stat} ->
        {:error, invalid_lock(path, "The installation lock has an unsupported file type.")}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp cleanup_stale(stale, previous_storage) do
    File.rm_rf(stale)

    if previous_storage do
      File.rm_rf(previous_storage)
    end

    :ok
  end

  defp read_owner(path) do
    owner_path = Path.join(path, @owner_file)

    with {:ok, bytes} <- File.read(owner_path),
         {:ok, owner} <- Jason.decode(bytes),
         true <- is_map(owner) and map_size(owner) == 2,
         :ok <- validate_owner(owner) do
      {:ok, owner}
    else
      _invalid ->
        {:error,
         Error.new(4, "install_lock_invalid", "The existing installation lock has no valid owner record.",
           details: %{"path" => path}
         )}
    end
  end

  defp read_validated_owner(path) do
    with {:ok, owner} <- read_owner(path),
         {:ok, _storage} <- previous_storage(path, owner["token"]) do
      {:ok, owner}
    end
  end

  defp recover_orphan_storages(path, opts) do
    parent = Path.dirname(path)
    prefix = Path.basename(path) <> ".owner."

    case File.ls(parent) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&String.starts_with?(&1, prefix))
        |> Enum.reduce_while(:ok, fn entry, :ok ->
          token = String.replace_prefix(entry, prefix, "")

          if byte_size(token) in 16..128 and safe_token?(token) do
            storage = Path.join(parent, entry)

            case recover_orphan_storage(path, storage, token, opts) do
              :ok -> {:cont, :ok}
              {:error, %Error{} = error} -> {:halt, {:error, error}}
            end
          else
            # Staged owner directories have a `.prepare` suffix and are never
            # candidates for publication. They cannot block the lock path.
            {:cont, :ok}
          end
        end)

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        {:error, lock_error("install_lock_failed", path, reason)}
    end
  end

  defp recover_orphan_storage(path, storage, token, opts) do
    if linked_storage?(path, storage) do
      :ok
    else
      case File.lstat(storage) do
        {:ok, %File.Stat{type: :directory}} -> recover_owner_directory(path, storage, token, opts)
        {:error, :enoent} -> :ok
        {:ok, _stat} -> {:error, invalid_lock(path, "An owner storage path has an unsupported file type.")}
        {:error, reason} -> {:error, lock_error("install_lock_failed", path, reason)}
      end
    end
  end

  defp recover_owner_directory(path, storage, token, opts) do
    with {:ok, %{"token" => ^token} = owner} <- read_owner(storage),
         {:ok, alive?} <- process_alive(owner["pid"], opts) do
      cond do
        linked_storage?(path, storage) ->
          :ok

        alive? ->
          {:error, install_in_progress(path, "Another installation is publishing the installation lock.")}

        true ->
          remove_dead_owner_storage(path, storage, owner)
      end
    else
      {:ok, _different_owner} -> {:error, invalid_lock(path, "An owner storage token does not match its path.")}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp remove_dead_owner_storage(path, storage, owner) do
    if linked_storage?(path, storage) do
      :ok
    else
      case File.lstat(storage) do
        {:error, :enoent} ->
          :ok

        {:ok, %File.Stat{type: :directory}} ->
          remove_unchanged_owner_storage(path, storage, owner)

        {:ok, _stat} ->
          {:error, invalid_lock(path, "An owner storage path changed type during recovery.")}

        {:error, reason} ->
          {:error, lock_error("install_lock_failed", storage, reason)}
      end
    end
  end

  defp remove_unchanged_owner_storage(path, storage, owner) do
    if read_owner(storage) == {:ok, owner} do
      case File.rm_rf(storage) do
        {:ok, _removed} -> :ok
        {:error, reason, failed_path} -> {:error, lock_error("install_lock_failed", failed_path, reason)}
      end
    else
      case File.lstat(storage) do
        {:error, :enoent} -> :ok
        _present -> {:error, invalid_lock(path, "An owner storage record changed during recovery.")}
      end
    end
  end

  defp linked_storage?(path, storage) do
    case File.read_link(path) do
      {:ok, ^storage} -> true
      _missing_or_different -> false
    end
  end

  defp ensure_no_reclaimer(path, opts) do
    gate = path <> @reclaim_suffix

    case File.lstat(gate) do
      {:error, :enoent} ->
        :ok

      {:ok, _stat} ->
        recover_existing_reclaimer(path, gate, opts)

      {:error, reason} ->
        {:error, lock_error("install_lock_failed", path, reason)}
    end
  end

  defp recover_existing_reclaimer(path, gate, opts) do
    with {:ok, owner} <- read_validated_owner(gate),
         {:ok, alive?} <- process_alive(owner["pid"], opts) do
      if alive? do
        {:error, install_in_progress(path, "Another installation is reconciling the installation lock.")}
      else
        remove_dead_reclaimer(path, gate, owner)
      end
    else
      {:error, %Error{} = error} ->
        case File.lstat(gate) do
          {:error, :enoent} -> :ok
          _present_or_unreadable -> {:error, error}
        end
    end
  end

  defp remove_dead_reclaimer(path, gate, owner) do
    stale = gate <> ".stale." <> owner["token"]

    with {:ok, storage} <- previous_storage(gate, owner["token"]),
         :ok <- File.rename(gate, stale) do
      cleanup_stale(stale, storage)
    else
      {:error, %Error{} = error} ->
        {:error, error}

      {:error, reason} when reason in [:enoent, :eexist, :enotempty] ->
        {:error, install_in_progress(path, "Another installation changed the reclaim gate.")}

      {:error, reason} ->
        {:error, lock_error("install_lock_failed", path, reason)}
    end
  end

  defp validate_owner(%{"pid" => pid, "token" => token}) when is_binary(pid) and is_binary(token) do
    if pid =~ ~r/^\d+$/ and byte_size(token) in 16..128 and safe_token?(token), do: :ok, else: {:error, :invalid_owner}
  end

  defp validate_owner(_owner), do: {:error, :invalid_owner}

  defp safe_token?(token), do: token =~ ~r/^[A-Za-z0-9_-]+$/

  defp process_alive(pid, opts) do
    case Keyword.get(opts, :process_alive) do
      check when is_function(check, 1) ->
        case check.(pid) do
          value when is_boolean(value) -> {:ok, value}
          _invalid -> {:error, lock_error("install_lock_probe_failed", "", :invalid_result)}
        end

      nil ->
        case System.find_executable("kill") do
          nil ->
            {:error, lock_error("install_lock_probe_failed", "", :kill_unavailable)}

          kill ->
            {_output, status} = System.cmd(kill, ["-0", pid], stderr_to_stdout: true)
            {:ok, status == 0}
        end
    end
  end

  defp release(path, token) do
    case read_owner(path) do
      {:ok, %{"token" => ^token}} ->
        release_owned(path, token)

      _missing_or_changed ->
        :ok
    end
  end

  defp release_owned(path, token) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :symlink}} ->
        storage = storage_path(path, token)

        with {:ok, ^storage} <- File.read_link(path),
             :ok <- File.rm(path),
             {:ok, _removed} <- File.rm_rf(storage) do
          :ok
        else
          _changed -> :ok
        end

      {:ok, %File.Stat{type: :directory}} ->
        with :ok <- File.rm(Path.join(path, @owner_file)), do: File.rmdir(path)

      _missing_or_changed ->
        :ok
    end
  end

  defp storage_path(path, token), do: path <> ".owner." <> token

  defp token do
    18 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end

  defp install_in_progress(path, message) do
    Error.new(4, "install_in_progress", message, details: %{"path" => path})
  end

  defp invalid_lock(path, message) do
    Error.new(4, "install_lock_invalid", message, details: %{"path" => path})
  end

  defp lock_error(code, path, reason) do
    Error.new(6, code, "The installation lock could not be acquired.",
      details: %{"path" => path, "reason" => inspect(reason)}
    )
  end
end
