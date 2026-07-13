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
    cargo_manifest_path = Path.join(root, "native/codex-loops/Cargo.toml")
    cargo_manifest = File.read!(cargo_manifest_path)
    [cargo_version] = Regex.run(~r/^version\s*=\s*"([^"]+)"/m, cargo_manifest, capture: :all_but_first)
    cargo_lock_path = Path.join(root, "native/codex-loops/Cargo.lock")
    cargo_lock = File.read!(cargo_lock_path)

    [cargo_lock_version] =
      Regex.run(
        ~r/\[\[package\]\]\nname = "codex-loops"\nversion = "([^"]+)"/,
        cargo_lock,
        capture: :all_but_first
      )

    expected = %{
      "VERSION" => version,
      "Mix project" => Mix.Project.config()[:version],
      "runtime module" => Workflow.PackageVersion.version(),
      "plugin manifest" => manifest["version"],
      "Rust control plane" => cargo_version,
      "Rust lockfile" => cargo_lock_version
    }

    mismatches =
      expected
      |> Enum.reject(fn {_surface, surface_version} -> surface_version == version end)
      |> Enum.map(fn {surface, surface_version} -> "#{surface}=#{inspect(surface_version)}" end)

    case mismatches do
      [] ->
        :ok

      _ ->
        Mix.raise("""
        Codex Loops package version surfaces are out of sync.

        Expected: #{version}
        Mismatched: #{Enum.join(mismatches, ", ")}
        """)
    end
  end
end

CheckPackageVersion.run(System.argv())
