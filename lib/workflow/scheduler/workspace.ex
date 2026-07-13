defmodule Workflow.Scheduler.Workspace do
  @moduledoc """
  Resolves the durable filesystem context for one scheduler run.

  Both the workflow source and workspace root are canonicalized through every
  symlink component before containment is checked. This prevents a source path
  that looks local from escaping the requested workspace through a symlink.
  """

  alias Workflow.Scheduler.Error
  alias Workflow.Script.Error, as: ScriptError

  @max_symlink_depth 40

  @enforce_keys [:script_path, :workspace_root]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          script_path: String.t(),
          workspace_root: String.t()
        }

  @spec resolve(String.t(), String.t() | nil) ::
          {:ok, t()} | {:error, Error.t() | ScriptError.t()}
  def resolve(script_path, requested_root) when is_binary(script_path) do
    with {:ok, {script_path, requested_root}} <- locate_script(script_path, requested_root),
         {:ok, canonical_script} <- canonical_file(script_path),
         {:ok, canonical_root} <- workspace_root(requested_root, canonical_script),
         :ok <- require_containment(canonical_script, canonical_root) do
      {:ok,
       %__MODULE__{
         script_path: canonical_script,
         workspace_root: canonical_root
       }}
    end
  end

  def resolve(script_path, _requested_root), do: {:error, Error.invalid_workspace_script(script_path, :invalid_path)}

  defp locate_script(path, requested_root) do
    case Path.type(path) do
      :absolute ->
        {:ok, {path, requested_root}}

      :relative ->
        locate_relative_script(path, requested_root)

      :volumerelative ->
        {:error, Error.invalid_workspace_script(path, :volume_relative)}
    end
  end

  defp locate_relative_script(path, root) when is_binary(root) and root != "" do
    if Path.type(root) == :absolute do
      {:ok, {Path.expand(path, root), root}}
    else
      {:error, Error.invalid_workspace_root(root, :not_absolute)}
    end
  end

  defp locate_relative_script(_path, root) do
    {:error, Error.invalid_workspace_root(root, :required_for_relative_script)}
  end

  defp workspace_root(nil, canonical_script) do
    canonical_script
    |> derive_root()
    |> canonical_directory()
  end

  defp workspace_root(root, _canonical_script) when not is_binary(root),
    do: {:error, Error.invalid_workspace_root(root, :invalid_type)}

  defp workspace_root("", _canonical_script), do: {:error, Error.invalid_workspace_root("", :empty)}

  defp workspace_root(root, _canonical_script) do
    if Path.type(root) == :absolute do
      canonical_directory(root)
    else
      {:error, Error.invalid_workspace_root(root, :not_absolute)}
    end
  end

  defp canonical_file(path) do
    case canonicalize(path) do
      {:ok, canonical} -> canonical_file_stat(path, canonical)
      {:error, {:canonicalize_failed, :enoent}} -> missing_script(path)
      {:error, {:canonicalize_failed, reason}} -> unreadable_script(path, reason)
    end
  end

  defp canonical_file_stat(path, canonical) do
    case File.stat(canonical) do
      {:ok, %File.Stat{type: :regular}} -> {:ok, canonical}
      {:ok, %File.Stat{}} -> missing_script(path)
      {:error, :enoent} -> missing_script(path)
      {:error, reason} -> unreadable_script(path, reason)
    end
  end

  defp missing_script(path) do
    {:error, ScriptError.new(:script_not_found, path, "workflow script not found: #{path}")}
  end

  defp unreadable_script(path, reason) do
    {:error,
     ScriptError.new(
       :compile,
       path,
       "cannot resolve workflow script: #{:file.format_error(reason)}"
     )}
  end

  defp canonical_directory(path) do
    with {:ok, canonical} <- canonicalize(path),
         {:ok, %File.Stat{type: :directory}} <- File.stat(canonical) do
      {:ok, canonical}
    else
      {:ok, %File.Stat{type: type}} ->
        {:error, Error.invalid_workspace_root(path, {:not_directory, type})}

      {:error, reason} ->
        {:error, Error.invalid_workspace_root(path, reason)}
    end
  end

  defp require_containment(script_path, workspace_root) do
    root_segments = Path.split(workspace_root)
    script_segments = Path.split(script_path)

    if length(script_segments) > length(root_segments) and
         Enum.take(script_segments, length(root_segments)) == root_segments do
      :ok
    else
      {:error, Error.script_outside_workspace(script_path, workspace_root)}
    end
  end

  # Conventional workflow files live below <workspace>/.codex/workflows. For
  # other paths, the source's containing directory is the narrowest safe default.
  defp derive_root(script_path) do
    directory = Path.dirname(script_path)
    segments = Path.split(directory)

    case last_workflows_marker(segments) do
      nil -> directory
      marker_index -> segments |> Enum.take(marker_index) |> join_segments()
    end
  end

  defp last_workflows_marker(segments) do
    segments
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.with_index()
    |> Enum.reduce(nil, fn
      {[".codex", "workflows"], index}, _last -> index
      {_other, _index}, last -> last
    end)
  end

  defp canonicalize(path) do
    expanded = Path.expand(path)
    [root | segments] = Path.split(expanded)

    case resolve_segments(root, [], segments, 0) do
      {:ok, canonical} -> {:ok, canonical}
      {:error, reason} -> {:error, {:canonicalize_failed, reason}}
    end
  end

  defp resolve_segments(root, resolved, [], _depth), do: {:ok, join_path(root, resolved)}

  defp resolve_segments(root, resolved, [segment | rest], depth) do
    candidate = join_path(root, resolved ++ [segment])

    case File.lstat(candidate) do
      {:ok, %File.Stat{type: :symlink}} ->
        if depth >= @max_symlink_depth do
          {:error, :too_many_symlinks}
        else
          with {:ok, target} <- :file.read_link_all(String.to_charlist(candidate)) do
            target = Path.expand(IO.chardata_to_string(target), join_path(root, resolved))
            [target_root | target_segments] = Path.split(target)
            resolve_segments(target_root, [], target_segments ++ rest, depth + 1)
          end
        end

      {:ok, _stat} ->
        resolve_segments(root, resolved ++ [segment], rest, depth)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp join_segments([root | segments]), do: join_path(root, segments)
  defp join_path(root, segments), do: Path.join([root | segments])
end
