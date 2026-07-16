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

  phase("Find risks through blind lenses")

  log(
    "running five independent finders before the intentional candidate-pool barrier; each finder sees the complete diff but not the other conclusions"
  )

  fanout width: 5, bind: :work, max_concurrency: 5 do
    lanes([
      [
        agent(
          """
          Review the current repository change through a line-by-line correctness lens. Remain read-only.

          Establish the exact changed scope with `git status --short`, `git diff`, and `git diff --cached`; include
          relevant untracked source/tests without reading generated, vendored, credential, or secret-bearing files.
          Read every diff hunk and the enclosing function or module. For each changed line ask which input, state,
          timing, or platform makes it wrong. Hunt for inverted conditions, off-by-one boundaries, absent values,
          wrong-variable copy/paste, swallowed errors, missing awaits/settlements, and malformed validation.

          Return every evidence-backed candidate with a stable id, file, line, one-line issue, concrete
          failure scenario, and smallest practical fix. Do not silently discard half-believed candidates—the later
          adjudicator will refute them. If nothing qualifies, say exactly which files and mechanisms you checked.
          Do not edit, format, stage, commit, reset, checkout, or clean files.
          """,
          label: "find:line-scan"
        )
      ],
      [
        agent(
          """
          Review the current repository change through a removed-behavior and invariant lens. Remain read-only.

          Establish the exact changed scope with `git status --short`, `git diff`, and `git diff --cached`; include
          relevant untracked source/tests without reading generated, vendored, credential, or secret-bearing files.
          For every deleted or replaced block, name the guard, ordering rule, failure path, compatibility behavior,
          cleanup, or test invariant it used to enforce, then trace where the new code re-establishes it. Treat a
          missing replacement as a candidate only when you can name the caller-visible consequence.

          Return every evidence-backed candidate with a stable id, file, line, one-line issue, concrete
          failure scenario, and smallest practical fix. Do not deduplicate against imagined work by other finders and
          do not pad. If nothing qualifies, state the removed mechanisms you traced. Do not modify the workspace.
          """,
          label: "find:removed-invariants"
        )
      ],
      [
        agent(
          """
          Review the current repository change through a cross-file caller/callee and public-contract lens. Remain
          read-only.

          Establish the exact changed scope with `git status --short`, `git diff`, and `git diff --cached`; include
          relevant untracked source/tests without reading generated, vendored, credential, or secret-bearing files.
          For changed functions, structs, events, CLI/MCP fields, and configuration, find callers and consumers. Check
          changed preconditions, return shapes, exceptions, ordering, defaults, compatibility, serialization, and
          whether a parallel edit makes an otherwise local call unsafe.

          Return every evidence-backed candidate with a stable id, file, line, one-line issue, concrete
          failure scenario, and smallest practical fix. Do not deduplicate against imagined work by other finders and
          do not pad. If nothing qualifies, state which contracts and consumers you traced. Do not modify the workspace.
          """,
          label: "find:cross-file"
        )
      ],
      [
        agent(
          """
          Review the current repository change through a concurrency, durability, security, and rollback lens. Remain
          read-only.

          Establish the exact changed scope with `git status --short`, `git diff`, and `git diff --cached`; include
          relevant untracked source/tests without reading generated, vendored, credential, or secret-bearing files.
          Trace concurrent ownership, backpressure, timeouts, retries, transaction boundaries, write-before-publish
          ordering, idempotency, authorization, untrusted input, cleanup, partial failure, service restart, and operator
          rollback. Require a constructible failure; do not report generic best-practice advice.

          Return every evidence-backed candidate with a stable id, file, line, one-line issue, concrete
          failure scenario, and smallest practical fix. Do not deduplicate against imagined work by other finders and
          do not pad. If nothing qualifies, state which boundaries you traced. Do not modify the workspace.
          """,
          label: "find:runtime-risk"
        )
      ],
      [
        agent(
          """
          Review the current repository change through a verification, operations, and documentation-consistency lens.
          Remain read-only.

          Establish the exact changed scope with `git status --short`, `git diff`, and `git diff --cached`; include
          relevant untracked source/tests without reading generated, vendored, credential, or secret-bearing files.
          Compare behavioral claims with narrow executable tests, install/release paths, telemetry and journal events,
          user-visible status/UI projections, and rollback instructions. Hunt for false-positive tests, missing negative
          cases, docs that assert an unenforced guarantee, and verification commands that do not exercise the change.

          Return every evidence-backed candidate with a stable id, file, line, one-line issue, concrete
          failure scenario, and smallest practical fix. Do not deduplicate against imagined work by other finders and
          do not pad. If nothing qualifies, state which claims and proof paths you checked. Do not modify the workspace.
          """,
          label: "find:proof-operations"
        )
      ]
    ])
  end

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

        Blind, perspective-diverse finder pool:
        <%= @work %>

        Re-open the cited files and diffs before accepting any claim. Deduplicate against the complete finder pool,
        keeping the strongest evidence for the same mechanism/location. Try to refute every candidate: reject it when
        the code contradicts it, a concrete invariant makes the failure impossible, or an existing guard handles it.
        Preserve a plausible risk when its mechanism is real and the triggering state is reachable but not proven.
        Trace changed inputs through callers, persistence and concurrency boundaries, public APIs, rollback behavior,
        and tests. Prefer targeted verification commands over broad test suites. A failed or unread finder is a coverage
        limit, not evidence that its lens passed.

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
