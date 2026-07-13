workflow "staff-level-elixir-adversarial-scan" do
  phase("scan")
  log("running a read-only staff-level Elixir adversarial scan across the repo")

  agent(
    """
    You are doing a read-only adversarial repository review against the Staff-Level Elixir skill.

    Workspace root:
    /Users/pedroproenca/Documents/Projects/codex-loops

    Rubric:
    /Users/pedroproenca/Documents/Projects/codex-loops/.agents/skills/staff-level-elixir/SKILL.md

    Scope:
    - Enumerate the complete repo file set with `git ls-files --cached --others --exclude-standard` from the workspace root. Include the file count in `scanned_file_count`.
    - Do not scan `.git`, `_build`, `deps`, `node_modules`, or generated cache directories unless they are explicitly listed by the command above.
    - Inspect every file that can affect Elixir, OTP, Ecto, Phoenix, LiveView, workflow execution, configuration, tests, or docs that prescribe runtime behavior.
    - Use `rg` across the complete file set for staff-level risk patterns: GenServer, Agent, ETS, Registry, Supervisor, DynamicSupervisor, rescue, raise, try, with, Task.async, async_stream, Task.start, String.to_atom, to_existing_atom, Enum, Stream, iodata, Repo, Ecto.Multi, preload, transaction, update_all, insert, update, delete, Phoenix, LiveView, mount, assign, stream, connected?, schemas, and web modules.
    - Read the rubric file and any referenced rule files that come up while judging concrete code.
    - Do not modify files, stage files, commit, run formatters, or run broad test suites.

    Output:
    Findings must be adversarial but evidence-based. Each finding must cite a concrete file and line. Use rule ids from the staff-level-elixir skill where possible. Set `verdict` to `findings` when any finding exists, otherwise `pass`.
    """,
    schema: %{
      "type" => "object",
      "required" => ["verdict", "scanned_file_count", "findings", "coverage_notes"],
      "properties" => %{
        "verdict" => %{"type" => "string"},
        "scanned_file_count" => %{"type" => "integer"},
        "findings" => %{
          "type" => "array",
          "items" => %{
            "type" => "object",
            "required" => [
              "rule_id",
              "severity",
              "file",
              "line",
              "issue",
              "evidence",
              "recommended_fix"
            ],
            "properties" => %{
              "rule_id" => %{"type" => "string"},
              "severity" => %{"type" => "string"},
              "file" => %{"type" => "string"},
              "line" => %{"type" => "integer"},
              "issue" => %{"type" => "string"},
              "evidence" => %{"type" => "string"},
              "recommended_fix" => %{"type" => "string"}
            }
          }
        },
        "coverage_notes" => %{"type" => "string"}
      }
    },
    retries: 1
  )

  return(:ok)
end
