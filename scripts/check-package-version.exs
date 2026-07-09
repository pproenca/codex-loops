defmodule CheckPackageVersion do
  @moduledoc false

  def run(args) do
    check? = args in [[], ["--check"]]

    if !check? do
      Mix.raise("usage: mix run --no-start scripts/check-package-version.exs [--check]")
    end

    root = File.cwd!()
    version = root |> Path.join("VERSION") |> File.read!() |> String.trim()
    manifest_path = Path.join(root, "plugins/codex-loops/.codex-plugin/plugin.json")
    manifest = manifest_path |> File.read!() |> Jason.decode!()

    expected = %{
      "VERSION" => version,
      "Mix project" => Mix.Project.config()[:version],
      "runtime module" => Workflow.PackageVersion.version(),
      "plugin manifest" => manifest["version"]
    }

    mismatches =
      expected
      |> Enum.reject(fn {_surface, surface_version} -> surface_version == version end)
      |> Enum.map(fn {surface, surface_version} -> "#{surface}=#{inspect(surface_version)}" end)

    case mismatches do
      [] ->
        check_generated_manifest!(manifest_path, version)

      _ ->
        Mix.raise("""
        Codex Loops package version surfaces are out of sync.

        Expected: #{version}
        Mismatched: #{Enum.join(mismatches, ", ")}
        """)
    end
  end

  defp check_generated_manifest!(manifest_path, version) do
    content = File.read!(manifest_path)
    expected = Regex.replace(~r/"version"\s*:\s*"[^"]+"/, content, ~s("version": "#{version}"), global: false)

    if content != expected do
      Mix.raise("""
      Codex Loops plugin manifest is not generated from VERSION.

      Run:
        mix run --no-start scripts/sync-package-version.exs --write
      """)
    end
  end
end

CheckPackageVersion.run(System.argv())
