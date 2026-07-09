defmodule Workflow.PackageVersionTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  @repo_root Path.expand("../..", __DIR__)

  test "Mix, runtime, and plugin manifest versions come from the package version source" do
    version = @repo_root |> Path.join("VERSION") |> File.read!() |> String.trim()

    manifest =
      @repo_root
      |> Path.join("plugins/codex-loops/.codex-plugin/plugin.json")
      |> File.read!()
      |> Jason.decode!()

    assert Workflow.PackageVersion.source_path() == Path.join(@repo_root, "VERSION")
    assert Mix.Project.config()[:version] == version
    assert Workflow.PackageVersion.version() == version
    assert manifest["version"] == version
  end

  test "codex-loops CLI reports the package version" do
    version = Workflow.PackageVersion.version()

    assert capture_io(fn -> assert :ok = Workflow.CLI.main(["--version"]) end) ==
             "codex-loops #{version}\n"
  end
end
