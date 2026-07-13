workflow "change-risk-report" do
  phase("Inventory the current change")
  log("Building an evidence-backed risk report from the current workspace without modifying files")

  let(
    :rows =
      agent(
        """
        Perform a read-only inventory of the repository's current change.

        Evidence scope:
        - Start with `git status --short`, `git diff --stat`, `git diff`, and `git diff --cached`.
        - Include relevant untracked source or test files reported by status, but do not read generated, vendored, credential, or secret-bearing files.
        - For every changed file, read enough surrounding code and tests to explain its responsibility, the behavioral change, and its plausible blast radius.
        - Use repository documentation and nearby tests to distinguish intended behavior from accidental churn.

        Safety:
        - This turn is strictly read-only. Do not edit, format, stage, commit, reset, checkout, delete, or create files.
        - Treat pre-existing user changes as evidence, never as work to clean up.
        - Report uncertainty explicitly when a file cannot be assessed from available evidence.

        Field semantics:
        - `summary` is a concise description of the complete current change.
        - `files` has one entry per materially changed file; `churn_lines` is an evidence-backed estimate from the diff, not invented precision.
        - `cross_cutting_risks` records risks spanning more than one file or subsystem.
        - `test_gaps` names behavior that the current tests do not prove.
        - `findings` contains only actionable risk findings. Each finding needs a stable id, concrete evidence, the issue, and a practical fix.
        """,
        label: "inventory:current-change",
        schema: %{
          "type" => "object",
          "additionalProperties" => false,
          "required" => [
            "summary",
            "files",
            "cross_cutting_risks",
            "test_gaps",
            "findings"
          ],
          "properties" => %{
            "summary" => %{"type" => "string"},
            "files" => %{
              "type" => "array",
              "items" => %{
                "type" => "object",
                "additionalProperties" => false,
                "required" => [
                  "path",
                  "status",
                  "responsibility",
                  "change_summary",
                  "churn_lines",
                  "risk_signals"
                ],
                "properties" => %{
                  "path" => %{"type" => "string"},
                  "status" => %{"type" => "string"},
                  "responsibility" => %{"type" => "string"},
                  "change_summary" => %{"type" => "string"},
                  "churn_lines" => %{"type" => "integer"},
                  "risk_signals" => %{
                    "type" => "array",
                    "items" => %{"type" => "string"}
                  }
                }
              }
            },
            "cross_cutting_risks" => %{
              "type" => "array",
              "items" => %{"type" => "string"}
            },
            "test_gaps" => %{
              "type" => "array",
              "items" => %{"type" => "string"}
            },
            "findings" => %{
              "type" => "array",
              "items" => %{
                "type" => "object",
                "additionalProperties" => false,
                "required" => ["id", "severity", "evidence", "issue", "fix"],
                "properties" => %{
                  "id" => %{"type" => "string"},
                  "severity" => %{
                    "type" => "string",
                    "enum" => ["low", "medium", "high", "critical"]
                  },
                  "evidence" => %{"type" => "string"},
                  "issue" => %{"type" => "string"},
                  "fix" => %{"type" => "string"}
                }
              }
            }
          }
        },
        retries: 1
      )
  )

  phase("Analyze failure modes")

  let(
    :draft =
      agent(
        ~P"""
        Produce a rigorous change-risk analysis from the inventory below. This is still a read-only turn.

        Inventory summary:
        <%= path(@rows, "/summary") %>

        Changed-file count:
        <%= count(@rows, "/files") %>

        Changed-file evidence:
        <%= path(@rows, "/files") %>

        Cross-cutting risks:
        <%= path(@rows, "/cross_cutting_risks") %>

        Test gaps:
        <%= path(@rows, "/test_gaps") %>

        Inventory findings:
        <%= numbered_findings(@rows, "/findings") %>

        Re-open the cited files and diffs before accepting any claim. Trace changed inputs through callers,
        persistence boundaries, concurrency boundaries, public APIs, rollback behavior, and tests. Separate
        demonstrated failures from plausible risks. Prefer targeted verification commands over broad test suites.

        The inserted structured values are workflow text renderings, not promised JSON serialization. Interpret
        their semantic fields and verify them against the workspace rather than parsing their textual appearance.

        Do not modify files, stage changes, or run destructive commands. Record a release recommendation that is
        proportional to evidence, including what remains unknown.
        """,
        label: "analyze:change-failure-modes",
        schema: %{
          "type" => "object",
          "additionalProperties" => false,
          "required" => [
            "risk_level",
            "executive_summary",
            "blast_radius",
            "failure_modes",
            "mitigations",
            "verification_plan",
            "release_recommendation",
            "findings"
          ],
          "properties" => %{
            "risk_level" => %{
              "type" => "string",
              "enum" => ["low", "medium", "high", "critical"]
            },
            "executive_summary" => %{"type" => "string"},
            "blast_radius" => %{
              "type" => "array",
              "items" => %{"type" => "string"}
            },
            "failure_modes" => %{
              "type" => "array",
              "items" => %{
                "type" => "object",
                "additionalProperties" => false,
                "required" => ["id", "likelihood", "impact", "evidence", "issue", "fix"],
                "properties" => %{
                  "id" => %{"type" => "string"},
                  "likelihood" => %{"type" => "string"},
                  "impact" => %{"type" => "string"},
                  "evidence" => %{"type" => "string"},
                  "issue" => %{"type" => "string"},
                  "fix" => %{"type" => "string"}
                }
              }
            },
            "mitigations" => %{
              "type" => "array",
              "items" => %{"type" => "string"}
            },
            "verification_plan" => %{
              "type" => "array",
              "items" => %{
                "type" => "object",
                "additionalProperties" => false,
                "required" => ["command", "purpose", "expected_result"],
                "properties" => %{
                  "command" => %{"type" => "string"},
                  "purpose" => %{"type" => "string"},
                  "expected_result" => %{"type" => "string"}
                }
              }
            },
            "release_recommendation" => %{"type" => "string"},
            "findings" => %{
              "type" => "array",
              "items" => %{
                "type" => "object",
                "additionalProperties" => false,
                "required" => ["id", "severity", "evidence", "issue", "fix"],
                "properties" => %{
                  "id" => %{"type" => "string"},
                  "severity" => %{"type" => "string"},
                  "evidence" => %{"type" => "string"},
                  "issue" => %{"type" => "string"},
                  "fix" => %{"type" => "string"}
                }
              }
            }
          }
        },
        retries: 1
      )
  )

  phase("Adversarial revision")

  let(
    :final =
      agent(
        ~P"""
        Revise the change-risk analysis into a defensible decision record. Remain read-only.

        Original inventory summary:
        <%= path(@rows, "/summary") %>

        Inventory finding count:
        <%= count(@rows, "/findings") %>

        Draft analysis findings:
        <%= numbered_findings(@draft, "/findings") %>

        Draft failure modes:
        <%= numbered_findings(@draft, "/failure_modes") %>

        Bounded diagnostic rendering of the complete draft (Elixir workflow text, not JSON):
        <%= truncate(@draft, 6000) %>

        Cold-read the current diff again. Remove duplicate or speculative claims, preserve dissent where evidence is
        incomplete, and make every remaining finding independently actionable. Check that each proposed command is
        non-destructive and scoped to the changed behavior. Do not edit, stage, commit, reset, or clean the workspace.

        The final report must distinguish must-fix defects from residual risk, say what evidence would change the
        recommendation, and avoid claiming that an unrun command passed.
        """,
        label: "revise:change-risk-decision",
        schema: %{
          "type" => "object",
          "additionalProperties" => false,
          "required" => [
            "risk_level",
            "executive_summary",
            "release_recommendation",
            "must_fix_before_merge",
            "residual_risks",
            "verification_plan",
            "findings",
            "evidence_limits"
          ],
          "properties" => %{
            "risk_level" => %{
              "type" => "string",
              "enum" => ["low", "medium", "high", "critical"]
            },
            "executive_summary" => %{"type" => "string"},
            "release_recommendation" => %{"type" => "string"},
            "must_fix_before_merge" => %{
              "type" => "array",
              "items" => %{"type" => "string"}
            },
            "residual_risks" => %{
              "type" => "array",
              "items" => %{"type" => "string"}
            },
            "verification_plan" => %{
              "type" => "array",
              "items" => %{"type" => "string"}
            },
            "findings" => %{
              "type" => "array",
              "items" => %{
                "type" => "object",
                "additionalProperties" => false,
                "required" => ["id", "severity", "evidence", "issue", "fix"],
                "properties" => %{
                  "id" => %{"type" => "string"},
                  "severity" => %{"type" => "string"},
                  "evidence" => %{"type" => "string"},
                  "issue" => %{"type" => "string"},
                  "fix" => %{"type" => "string"}
                }
              }
            },
            "evidence_limits" => %{"type" => "string"}
          }
        },
        retries: 1
      )
  )

  emit(~P"""
  # Change Risk Report

  **Changed files:** <%= count(@rows, "/files") %>
  **Risk level:** <%= path(@final, "/risk_level") %>
  **Actionable finding count:** <%= count(@final, "/findings") %>

  ## Executive summary

  <%= path(@final, "/executive_summary") %>

  ## Release recommendation

  <%= path(@final, "/release_recommendation") %>

  ## Actionable findings

  <%= numbered_findings(@final, "/findings") %>

  ## Must fix before merge

  <%= path(@final, "/must_fix_before_merge") %>

  ## Verification plan

  <%= path(@final, "/verification_plan") %>

  ## Residual risk and evidence limits

  <%= path(@final, "/residual_risks") %>

  <%= path(@final, "/evidence_limits") %>

  _Structured collections above use the workflow's textual rendering; this report does not claim they are JSON._
  """)
end
