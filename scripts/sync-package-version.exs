defmodule SyncPackageVersion do
  @moduledoc false

  @manifest_path "plugins/codex-loops/.codex-plugin/plugin.json"
  @version_pattern ~r/"version"\s*:\s*"[^"]+"/

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
      {@manifest_path, generated_manifest(version)}
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
end

SyncPackageVersion.run(System.argv())
