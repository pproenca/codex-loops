defmodule SyncPackageVersion do
  @moduledoc false

  @manifest_path "plugins/codex-loops/.codex-plugin/plugin.json"
  @cargo_manifest_path "native/codex-loops/Cargo.toml"
  @cargo_lock_path "native/codex-loops/Cargo.lock"
  @version_pattern ~r/"version"\s*:\s*"[^"]+"/
  @cargo_version_pattern ~r/^version\s*=\s*"[^"]+"/m
  @cargo_lock_version_pattern ~r/(\[\[package\]\]\nname = "codex-loops"\nversion = ")[^"]+("\n)/

  def run(["--check"]) do
    case stale_files() do
      [] ->
        :ok

      paths ->
        Mix.raise("""
        Codex Loops package version generated files are stale.

        Run:
          mix run --no-start scripts/sync-package-version.exs --write

        Stale:
          #{Enum.join(paths, "\n  ")}
        """)
    end
  end

  def run(["--write"]) do
    Enum.each(generated_files(), fn {path, content} ->
      File.write!(path, content)
    end)
  end

  def run(_args) do
    Mix.raise("usage: mix run --no-start scripts/sync-package-version.exs [--check | --write]")
  end

  defp stale_files do
    generated_files()
    |> Enum.reject(fn {path, content} -> File.read!(path) == content end)
    |> Enum.map(fn {path, _content} -> path end)
  end

  defp generated_files do
    version = "VERSION" |> File.read!() |> String.trim()

    [
      {@manifest_path,
       replace_version!(
         @manifest_path,
         @version_pattern,
         ~s("version": "#{version}"),
         "top-level version field"
       )},
      {@cargo_manifest_path,
       replace_version!(
         @cargo_manifest_path,
         @cargo_version_pattern,
         ~s(version = "#{version}"),
         "package version field"
       )},
      {@cargo_lock_path,
       replace_version!(
         @cargo_lock_path,
         @cargo_lock_version_pattern,
         fn _match, prefix, suffix -> prefix <> version <> suffix end,
         "codex-loops package version"
       )}
    ]
  end

  defp replace_version!(path, pattern, replacement, field) do
    content = File.read!(path)

    if Regex.match?(pattern, content) do
      Regex.replace(pattern, content, replacement, global: false)
    else
      Mix.raise("#{path} does not contain the #{field}")
    end
  end
end

SyncPackageVersion.run(System.argv())
