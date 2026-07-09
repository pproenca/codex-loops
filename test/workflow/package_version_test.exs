defmodule Workflow.PackageVersionTest do
  use ExUnit.Case, async: true

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
    cli = Path.join(@repo_root, "rel/overlays/bin/codex-loops")

    assert File.exists?(cli)

    assert {output, 0} =
             System.cmd(cli, ["--version"], env: [{"CODEX_LOOPS_PACKAGE_VERSION", version}])

    assert output == "codex-loops #{version}\n"
  end

  test "codex-loops CLI discovers the package version from release metadata" do
    version = Workflow.PackageVersion.version()
    source_cli = Path.join(@repo_root, "rel/overlays/bin/codex-loops")
    release_root = Path.join(System.tmp_dir!(), "codex_loops_cli_test_#{System.unique_integer([:positive])}")
    cli = Path.join(release_root, "bin/codex-loops")
    start_erl_data = Path.join(release_root, "releases/start_erl.data")

    File.mkdir_p!(Path.dirname(cli))
    File.mkdir_p!(Path.dirname(start_erl_data))
    File.cp!(source_cli, cli)
    File.chmod!(cli, 0o755)
    File.write!(start_erl_data, "28.4 #{version}\n")

    try do
      assert {output, 0} = System.cmd(cli, ["--version"], env: [{"CODEX_LOOPS_PACKAGE_VERSION", nil}])
      assert output == "codex-loops #{version}\n"
    after
      File.rm_rf(release_root)
    end
  end
end
