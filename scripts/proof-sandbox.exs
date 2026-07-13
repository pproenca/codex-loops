defmodule ProofSandbox do
  @moduledoc false

  def run do
    repo_root = Path.expand("..", __DIR__)
    executable = Path.join(repo_root, "_build/dev-bundle/bin/codex-loops")
    temp_root = Path.join(System.tmp_dir!(), "codex-loops-sandbox-proof-#{System.unique_integer([:positive])}")
    home = Path.join(temp_root, "home")
    codex_home = Path.join(temp_root, "codex-home")
    artifact_dir = Path.join(temp_root, "artifacts")
    codex = Path.join(temp_root, "codex")

    try do
      File.mkdir_p!(Path.join(home, ".codex/workflows"))
      File.mkdir_p!(codex_home)
      File.write!(codex, "#!/bin/sh\nprintf 'codex-cli 0.0.0\\n'\n")
      File.chmod!(codex, 0o755)

      File.write!(
        Path.join(home, ".codex/workflows/codex-binding.json"),
        JSON.encode!(%{"path" => codex, "version" => "codex-cli 0.0.0"})
      )

      env = [{"HOME", home}, {"CODEX_HOME", codex_home}]

      {output, 0} =
        System.cmd(
          executable,
          [
            "sandbox-run",
            Path.join(repo_root, ".codex/workflows/smoke.exs"),
            "--provider",
            "mock",
            "--output",
            artifact_dir,
            "--timeout-seconds",
            "60",
            "--json"
          ],
          env: env,
          stderr_to_stdout: true
        )

      result = JSON.decode!(output)
      assert!(result["ok"] == true, "sandbox-run should succeed")
      assert!(result["state"] == "completed", "sandbox-run should complete")

      for file <- [
            "manifest.json",
            "initialize.json",
            "tools.json",
            "validation.json",
            "start.json",
            "status.json",
            "inspect.json",
            "open-ui.json",
            "mcp-transcript.jsonl",
            "journal.sqlite",
            "git-status.txt",
            "git-diff.patch",
            "runtime/scheduler.log"
          ] do
        assert!(File.regular?(Path.join(artifact_dir, file)), "missing sandbox artifact #{file}")
      end

      manifest = artifact_dir |> Path.join("manifest.json") |> File.read!() |> JSON.decode!()
      status = artifact_dir |> Path.join("status.json") |> File.read!() |> JSON.decode!()
      transcript = artifact_dir |> Path.join("mcp-transcript.jsonl") |> File.stream!() |> Enum.to_list()

      assert!(manifest["format"] == "codex-loops.sandbox.v1", "sandbox manifest format should be stable")
      assert!(manifest["provider"] == "mock", "sandbox manifest should record the provider")
      assert!(manifest["state"] == "completed", "sandbox manifest should record completion")
      assert!(status["data"]["state"] == "completed", "status artifact should record completion")
      assert!(length(transcript) >= 10, "MCP transcript should include the lifecycle calls")

      worktree = result["worktree"]
      File.write!(Path.join(worktree, "sandbox-dirty-proof.txt"), "retain me\n")

      {blocked, 4} =
        System.cmd(executable, ["sandbox-clean", artifact_dir, "--json"],
          env: env,
          stderr_to_stdout: true
        )

      blocked = JSON.decode!(blocked)
      assert!(blocked["error"]["code"] == "sandbox_worktree_dirty", "dirty cleanup should fail closed")
      assert!(File.dir?(worktree), "dirty cleanup should retain the worktree")

      {cleaned, 0} =
        System.cmd(executable, ["sandbox-clean", artifact_dir, "--force", "--json"],
          env: env,
          stderr_to_stdout: true
        )

      cleaned = JSON.decode!(cleaned)
      assert!(cleaned["removed"] == true, "forced cleanup should remove the sandbox")
      assert!(not File.exists?(artifact_dir), "sandbox artifacts should be removed")
      IO.puts("Retained MCP sandbox run/inspect/cleanup proof passed")
    after
      File.rm_rf(temp_root)
    end
  end

  defp assert!(true, _message), do: :ok
  defp assert!(false, message), do: raise(message)
end

ProofSandbox.run()
