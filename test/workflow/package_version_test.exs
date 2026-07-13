defmodule Workflow.PackageVersionTest do
  use ExUnit.Case, async: false

  @repo_root Path.expand("../..", __DIR__)

  test "Mix, runtime, and plugin manifest versions come from the package version source" do
    version = @repo_root |> Path.join("VERSION") |> File.read!() |> String.trim()

    manifest =
      @repo_root
      |> Path.join("plugins/codex-loops/.codex-plugin/plugin.json")
      |> File.read!()
      |> Jason.decode!()

    assert Mix.Project.config()[:version] == version
    assert Workflow.PackageVersion.version() == version
    assert manifest["version"] == version
  end

  test "version sync updates the plugin manifest" do
    root =
      Path.join(
        System.tmp_dir!(),
        "codex-loops-version-sync-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf(root) end)
    File.mkdir_p!(Path.join(root, "scripts"))
    File.mkdir_p!(Path.join(root, "plugins/codex-loops/.codex-plugin"))

    for path <- [
          "scripts/sync-package-version.exs",
          "plugins/codex-loops/.codex-plugin/plugin.json"
        ] do
      File.cp!(Path.join(@repo_root, path), Path.join(root, path))
    end

    File.write!(Path.join(root, "VERSION"), "9.8.7\n")

    assert {"", 0} =
             System.cmd("elixir", ["scripts/sync-package-version.exs", "--write"], cd: root)

    manifest =
      root
      |> Path.join("plugins/codex-loops/.codex-plugin/plugin.json")
      |> File.read!()
      |> Jason.decode!()

    assert manifest["version"] == "9.8.7"

    assert {"", 0} =
             System.cmd("elixir", ["scripts/sync-package-version.exs", "--check"], cd: root)
  end
end
