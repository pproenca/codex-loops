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
      {@manifest_path, generated_manifest(version)},
      {@cargo_manifest_path, generated_cargo_manifest(version)},
      {@cargo_lock_path, generated_cargo_lock(version)}
    ]
  end

  defp generated_manifest(version) do
    content = File.read!(@manifest_path)

    if Regex.match?(@version_pattern, content) do
      Regex.replace(@version_pattern, content, ~s("version": "#{version}"), global: false)
    else
      Mix.raise("#{@manifest_path} does not contain a top-level version field")
    end
  end

  defp generated_cargo_manifest(version) do
    content = File.read!(@cargo_manifest_path)

    if Regex.match?(@cargo_version_pattern, content) do
      Regex.replace(@cargo_version_pattern, content, ~s(version = "#{version}"), global: false)
    else
      Mix.raise("#{@cargo_manifest_path} does not contain a package version field")
    end
  end

  defp generated_cargo_lock(version) do
    content = File.read!(@cargo_lock_path)

    if Regex.match?(@cargo_lock_version_pattern, content) do
      Regex.replace(@cargo_lock_version_pattern, content, fn _match, prefix, suffix ->
        prefix <> version <> suffix
      end)
    else
      Mix.raise("#{@cargo_lock_path} does not contain the codex-loops package version")
    end
  end
end

SyncPackageVersion.run(System.argv())
