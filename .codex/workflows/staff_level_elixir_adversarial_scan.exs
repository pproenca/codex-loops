workflow "staff-level-elixir-adversarial-scan" do
  phase("Scope")
  log("scouting the complete repository before the adversarial review fan-out")

  let(
    :rows =
      agent(
        """
        Build a read-only scope inventory for a staff-level Elixir/OTP review of this repository.

        Start at the workspace root. Enumerate the complete reviewable file set with
        `git ls-files --cached --others --exclude-standard`. Do not infer coverage from a directory listing.
        Exclude generated dependency/build/cache directories unless the command explicitly lists a source file there.

        Read `.agents/skills/staff-level-elixir/SKILL.md` and map source, test, configuration, and runtime-prescribing
        documentation into these areas: OTP/process ownership; failure semantics; concurrency/shared state; Elixir data
        idioms; Ecto/data access; Phoenix/LiveView; provider/workflow durability. Record whether Ecto, Phoenix, and
        LiveView are actually present so later reviewers can mark absent domains not-applicable rather than inventing
        findings.

        This is a map, not a critique. Do not edit files, run formatters, stage, commit, reset, checkout, clean, or run
        broad test suites. Report every unreadable or deliberately excluded area as a coverage limit.
        """,
        label: "scope:repository",
        schema: %{
          "type" => "object",
          "additionalProperties" => false,
          "required" => [
            "scanned_file_count",
            "areas",
            "ecto_present",
            "phoenix_present",
            "liveview_present",
            "coverage_limits"
          ],
          "properties" => %{
            "scanned_file_count" => %{"type" => "integer", "minimum" => 0},
            "areas" => %{
              "type" => "array",
              "items" => %{
                "type" => "object",
                "additionalProperties" => false,
                "required" => ["name", "files", "reason"],
                "properties" => %{
                  "name" => %{"type" => "string"},
                  "files" => %{"type" => "array", "items" => %{"type" => "string"}},
                  "reason" => %{"type" => "string"}
                }
              }
            },
            "ecto_present" => %{"type" => "boolean"},
            "phoenix_present" => %{"type" => "boolean"},
            "liveview_present" => %{"type" => "boolean"},
            "coverage_limits" => %{"type" => "array", "items" => %{"type" => "string"}}
          }
        },
        retries: 1
      )
  )

  phase("Find")

  log(
    "running five blind, perspective-diverse finders; the join is intentional because adjudication needs the full candidate pool"
  )

  fanout width: 5, bind: :work, max_concurrency: 5 do
    lanes([
      [
        agent(
          """
          Perform a read-only adversarial review through the OTP ownership and supervision lens.

          Enumerate the complete repo file set with `git ls-files --cached --others --exclude-standard`. Read
          `.agents/skills/staff-level-elixir/SKILL.md` plus the relevant `otp-*` and `err-*` references before judging.
          Inspect every source, test, config, and runtime-prescribing doc that can affect process ownership, startup,
          supervision, restart behavior, or failure signaling.

          Hunt specifically for unjustified GenServers, hot reads serialized through one mailbox, unsupervised/manual
          restart logic, blocking `init/1`, exception control flow, blanket rescue, masked crashes, and expected failures
          represented as raises or lossy strings. Trace each mechanism far enough to name a concrete runtime consequence.

          Return every evidence-backed candidate; do not deduplicate against imagined work by other agents and do not pad.
          A candidate needs a stable id, exact file and line, rule id, concrete evidence, a failure scenario, and the
          smallest architectural correction. Mark unread or not-applicable scope explicitly. Do not modify the workspace.
          """,
          label: "find:otp-failure",
          schema: %{
            "type" => "object",
            "additionalProperties" => false,
            "required" => ["lens", "scanned_file_count", "findings", "coverage_gaps"],
            "properties" => %{
              "lens" => %{"type" => "string"},
              "scanned_file_count" => %{"type" => "integer", "minimum" => 0},
              "findings" => %{
                "type" => "array",
                "items" => %{
                  "type" => "object",
                  "additionalProperties" => false,
                  "required" => [
                    "id",
                    "rule_id",
                    "severity",
                    "file",
                    "line",
                    "issue",
                    "evidence",
                    "failure_scenario",
                    "recommended_fix"
                  ],
                  "properties" => %{
                    "id" => %{"type" => "string"},
                    "rule_id" => %{"type" => "string"},
                    "severity" => %{"type" => "string", "enum" => ["low", "medium", "high", "critical"]},
                    "file" => %{"type" => "string"},
                    "line" => %{"type" => "integer", "minimum" => 1},
                    "issue" => %{"type" => "string"},
                    "evidence" => %{"type" => "string"},
                    "failure_scenario" => %{"type" => "string"},
                    "recommended_fix" => %{"type" => "string"}
                  }
                }
              },
              "coverage_gaps" => %{"type" => "array", "items" => %{"type" => "string"}}
            }
          },
          retries: 1
        )
      ],
      [
        agent(
          """
          Perform a read-only adversarial review through the concurrency, backpressure, and shared-state lens.

          Enumerate the complete repo file set with `git ls-files --cached --others --exclude-standard`. Read
          `.agents/skills/staff-level-elixir/SKILL.md` plus the relevant `conc-*`, `otp-ets-*`, and task references.
          Inspect runtime source, tests, configuration, and docs that prescribe concurrency or durability.

          Hunt for unbounded or linked fan-out, missing timeouts, fire-and-forget work outside supervision, atom creation
          from external input, mailbox bottlenecks, check-then-act races, hidden push without demand, task failure that can
          crash an unrelated owner, and concurrency caps documented but not enforced. In this scheduler, also trace the
          append-before-publish and paid-attempt-before-dispatch invariants rather than treating a test name as proof.

          Return every evidence-backed candidate; do not deduplicate against imagined work by other agents and do not pad.
          A candidate needs a stable id, exact file and line, rule id, concrete evidence, a failure scenario, and the
          smallest architectural correction. Mark unread or not-applicable scope explicitly. Do not modify the workspace.
          """,
          label: "find:concurrency",
          schema: %{
            "type" => "object",
            "additionalProperties" => false,
            "required" => ["lens", "scanned_file_count", "findings", "coverage_gaps"],
            "properties" => %{
              "lens" => %{"type" => "string"},
              "scanned_file_count" => %{"type" => "integer", "minimum" => 0},
              "findings" => %{
                "type" => "array",
                "items" => %{
                  "type" => "object",
                  "additionalProperties" => false,
                  "required" => [
                    "id",
                    "rule_id",
                    "severity",
                    "file",
                    "line",
                    "issue",
                    "evidence",
                    "failure_scenario",
                    "recommended_fix"
                  ],
                  "properties" => %{
                    "id" => %{"type" => "string"},
                    "rule_id" => %{"type" => "string"},
                    "severity" => %{"type" => "string", "enum" => ["low", "medium", "high", "critical"]},
                    "file" => %{"type" => "string"},
                    "line" => %{"type" => "integer", "minimum" => 1},
                    "issue" => %{"type" => "string"},
                    "evidence" => %{"type" => "string"},
                    "failure_scenario" => %{"type" => "string"},
                    "recommended_fix" => %{"type" => "string"}
                  }
                }
              },
              "coverage_gaps" => %{"type" => "array", "items" => %{"type" => "string"}}
            }
          },
          retries: 1
        )
      ],
      [
        agent(
          """
          Perform a read-only adversarial review through the Elixir data and language-idiom lens.

          Enumerate the complete repo file set with `git ls-files --cached --others --exclude-standard`. Read
          `.agents/skills/staff-level-elixir/SKILL.md` plus the relevant `data-*` references. Inspect source, tests,
          build scripts, templates, and runtime-prescribing docs.

          Hunt for shape branching that should be explicit clauses, eager collection work over large or early-exit data,
          lazy streams that are never consumed, repeated binary concatenation, opaque or subject-changing pipe chains,
          needless macros/compile-time coupling, hand-transliterated loops, huge data structures, and raw maps or flags
          that obscure a real state machine. Require a concrete correctness, memory, latency, or maintainability cost;
          do not report style preferences.

          Return every evidence-backed candidate; do not deduplicate against imagined work by other agents and do not pad.
          A candidate needs a stable id, exact file and line, rule id, concrete evidence, a failure scenario, and the
          smallest architectural correction. Mark unread or not-applicable scope explicitly. Do not modify the workspace.
          """,
          label: "find:data-idioms",
          schema: %{
            "type" => "object",
            "additionalProperties" => false,
            "required" => ["lens", "scanned_file_count", "findings", "coverage_gaps"],
            "properties" => %{
              "lens" => %{"type" => "string"},
              "scanned_file_count" => %{"type" => "integer", "minimum" => 0},
              "findings" => %{
                "type" => "array",
                "items" => %{
                  "type" => "object",
                  "additionalProperties" => false,
                  "required" => [
                    "id",
                    "rule_id",
                    "severity",
                    "file",
                    "line",
                    "issue",
                    "evidence",
                    "failure_scenario",
                    "recommended_fix"
                  ],
                  "properties" => %{
                    "id" => %{"type" => "string"},
                    "rule_id" => %{"type" => "string"},
                    "severity" => %{"type" => "string", "enum" => ["low", "medium", "high", "critical"]},
                    "file" => %{"type" => "string"},
                    "line" => %{"type" => "integer", "minimum" => 1},
                    "issue" => %{"type" => "string"},
                    "evidence" => %{"type" => "string"},
                    "failure_scenario" => %{"type" => "string"},
                    "recommended_fix" => %{"type" => "string"}
                  }
                }
              },
              "coverage_gaps" => %{"type" => "array", "items" => %{"type" => "string"}}
            }
          },
          retries: 1
        )
      ],
      [
        agent(
          """
          Perform a read-only adversarial review through the Ecto, atomicity, and boundary lens.

          Enumerate the complete repo file set with `git ls-files --cached --others --exclude-standard`. Read
          `.agents/skills/staff-level-elixir/SKILL.md` plus all relevant `ecto-*` and `phx-context-*` references. First
          prove whether Ecto is present. If it is absent, return no fabricated Ecto findings and explain the N/A scope.

          Where applicable, hunt for N+1 preloads, non-atomic multi-write operations, uniqueness checked before insert,
          read-modify-write counters, unbounded `Repo.all`, long cursor transactions without explicit tradeoffs, Repo or
          schema access from the web layer, and persistence claims in docs/tests that code does not actually enforce.
          Trace each finding to the database/runtime consequence and the caller-visible failure.

          Return every evidence-backed candidate; do not deduplicate against imagined work by other agents and do not pad.
          A candidate needs a stable id, exact file and line, rule id, concrete evidence, a failure scenario, and the
          smallest architectural correction. Mark unread or not-applicable scope explicitly. Do not modify the workspace.
          """,
          label: "find:ecto-boundary",
          schema: %{
            "type" => "object",
            "additionalProperties" => false,
            "required" => ["lens", "scanned_file_count", "findings", "coverage_gaps"],
            "properties" => %{
              "lens" => %{"type" => "string"},
              "scanned_file_count" => %{"type" => "integer", "minimum" => 0},
              "findings" => %{
                "type" => "array",
                "items" => %{
                  "type" => "object",
                  "additionalProperties" => false,
                  "required" => [
                    "id",
                    "rule_id",
                    "severity",
                    "file",
                    "line",
                    "issue",
                    "evidence",
                    "failure_scenario",
                    "recommended_fix"
                  ],
                  "properties" => %{
                    "id" => %{"type" => "string"},
                    "rule_id" => %{"type" => "string"},
                    "severity" => %{"type" => "string", "enum" => ["low", "medium", "high", "critical"]},
                    "file" => %{"type" => "string"},
                    "line" => %{"type" => "integer", "minimum" => 1},
                    "issue" => %{"type" => "string"},
                    "evidence" => %{"type" => "string"},
                    "failure_scenario" => %{"type" => "string"},
                    "recommended_fix" => %{"type" => "string"}
                  }
                }
              },
              "coverage_gaps" => %{"type" => "array", "items" => %{"type" => "string"}}
            }
          },
          retries: 1
        )
      ],
      [
        agent(
          """
          Perform a read-only adversarial review through the Phoenix/LiveView and cross-layer completeness lens.

          Enumerate the complete repo file set with `git ls-files --cached --others --exclude-standard`. Read
          `.agents/skills/staff-level-elixir/SKILL.md` plus all relevant `phx-*` references. First prove whether Phoenix
          and LiveView are present. Mark absent mechanisms N/A instead of inventing findings.

          Where applicable, hunt for Repo calls across the context boundary, repeated disconnected/connected mount side
          effects, large or growing lists in socket assigns, unscoped PubSub topics, blocking work in callbacks, missing
          per-event authorization, and UI state that claims durability not present in the journal. Also perform a fresh
          cross-layer sweep for mismatches between runtime code, tests, CLI/MCP surfaces, LiveView projections, and docs.

          Return every evidence-backed candidate; do not deduplicate against imagined work by other agents and do not pad.
          A candidate needs a stable id, exact file and line, rule id, concrete evidence, a failure scenario, and the
          smallest architectural correction. Mark unread or not-applicable scope explicitly. Do not modify the workspace.
          """,
          label: "find:phoenix-completeness",
          schema: %{
            "type" => "object",
            "additionalProperties" => false,
            "required" => ["lens", "scanned_file_count", "findings", "coverage_gaps"],
            "properties" => %{
              "lens" => %{"type" => "string"},
              "scanned_file_count" => %{"type" => "integer", "minimum" => 0},
              "findings" => %{
                "type" => "array",
                "items" => %{
                  "type" => "object",
                  "additionalProperties" => false,
                  "required" => [
                    "id",
                    "rule_id",
                    "severity",
                    "file",
                    "line",
                    "issue",
                    "evidence",
                    "failure_scenario",
                    "recommended_fix"
                  ],
                  "properties" => %{
                    "id" => %{"type" => "string"},
                    "rule_id" => %{"type" => "string"},
                    "severity" => %{"type" => "string", "enum" => ["low", "medium", "high", "critical"]},
                    "file" => %{"type" => "string"},
                    "line" => %{"type" => "integer", "minimum" => 1},
                    "issue" => %{"type" => "string"},
                    "evidence" => %{"type" => "string"},
                    "failure_scenario" => %{"type" => "string"},
                    "recommended_fix" => %{"type" => "string"}
                  }
                }
              },
              "coverage_gaps" => %{"type" => "array", "items" => %{"type" => "string"}}
            }
          },
          retries: 1
        )
      ]
    ])
  end

  phase("Adjudicate")
  log("deduplicating the complete finder pool and adversarially checking every surviving claim against source")

  let(
    :draft =
      agent(
        ~P"""
        Adjudicate a staff-level Elixir repository review. Remain read-only.

        Scope inventory:
        <%= @rows %>

        Blind finder results:
        <%= @work %>

        Treat the inserted values as workflow text renderings, not guaranteed JSON. Re-open every cited file and line.
        Try to refute each candidate: reject it when the code contradicts it, an invariant makes the failure impossible,
        or a concrete guard already handles it. Keep a candidate as plausible when the mechanism is real and its runtime
        state is reachable but not proven by a deterministic reproduction. Never turn an unreadable file, failed finder,
        or missing citation into a pass.

        Deduplicate only candidates with the same mechanism and location. Preserve the strongest evidence and list merged
        ids. Return all confirmed/plausible findings; there is no top-N cap. Put refuted candidates and infrastructure or
        evidence failures into their own arrays. Reconcile finder file counts with the inventory and report every coverage
        gap or disagreement. Do not modify files or run broad test suites.
        """,
        label: "adjudicate:candidates",
        schema: %{
          "type" => "object",
          "additionalProperties" => false,
          "required" => [
            "verdict",
            "scanned_file_count",
            "findings",
            "refuted_candidates",
            "unverified_candidates",
            "coverage_notes",
            "dropped_coverage"
          ],
          "properties" => %{
            "verdict" => %{"type" => "string", "enum" => ["pass", "findings", "inconclusive"]},
            "scanned_file_count" => %{"type" => "integer", "minimum" => 0},
            "findings" => %{
              "type" => "array",
              "items" => %{
                "type" => "object",
                "additionalProperties" => false,
                "required" => [
                  "id",
                  "merged_ids",
                  "rule_id",
                  "severity",
                  "adjudication",
                  "file",
                  "line",
                  "issue",
                  "evidence",
                  "failure_scenario",
                  "recommended_fix"
                ],
                "properties" => %{
                  "id" => %{"type" => "string"},
                  "merged_ids" => %{"type" => "array", "items" => %{"type" => "string"}},
                  "rule_id" => %{"type" => "string"},
                  "severity" => %{"type" => "string", "enum" => ["low", "medium", "high", "critical"]},
                  "adjudication" => %{"type" => "string", "enum" => ["confirmed", "plausible"]},
                  "file" => %{"type" => "string"},
                  "line" => %{"type" => "integer", "minimum" => 1},
                  "issue" => %{"type" => "string"},
                  "evidence" => %{"type" => "string"},
                  "failure_scenario" => %{"type" => "string"},
                  "recommended_fix" => %{"type" => "string"}
                }
              }
            },
            "refuted_candidates" => %{
              "type" => "array",
              "items" => %{
                "type" => "object",
                "additionalProperties" => false,
                "required" => ["id", "reason", "evidence"],
                "properties" => %{
                  "id" => %{"type" => "string"},
                  "reason" => %{"type" => "string"},
                  "evidence" => %{"type" => "string"}
                }
              }
            },
            "unverified_candidates" => %{
              "type" => "array",
              "items" => %{
                "type" => "object",
                "additionalProperties" => false,
                "required" => ["id", "reason"],
                "properties" => %{
                  "id" => %{"type" => "string"},
                  "reason" => %{"type" => "string"}
                }
              }
            },
            "coverage_notes" => %{"type" => "array", "items" => %{"type" => "string"}},
            "dropped_coverage" => %{"type" => "array", "items" => %{"type" => "string"}}
          }
        },
        retries: 1
      )
  )

  phase("Completeness")
  log("cold-reading the adjudicated report only for missed modalities, unverified claims, and unread evidence")

  let(
    :final =
      agent(
        ~P"""
        Perform a fresh, read-only completeness audit of this staff-level Elixir review.

        Original scope inventory:
        <%= @rows %>

        Adjudicated report:
        <%= @draft %>

        Do not merely rephrase or re-confirm the report. Look only for missing review modalities, repository areas that
        were not actually read, unverified claims incorrectly treated as findings or passes, refutations without quoted
        code evidence, duplicate mechanisms that were not merged, and staff-level rules whose concrete risk patterns were
        never searched. Re-open cited source and run narrow read-only searches as needed.

        Return a corrected complete report in the same semantic shape. Add genuinely missed evidence-backed findings,
        move unsupported findings to unverified or refuted as appropriate, and preserve every valid prior finding. There
        is no top-N cap. If coverage is incomplete, verdict must be `inconclusive` and `dropped_coverage` must say exactly
        what was not proven. Do not modify files, format, stage, commit, or run broad tests.
        """,
        label: "critic:completeness",
        schema: %{
          "type" => "object",
          "additionalProperties" => false,
          "required" => [
            "verdict",
            "scanned_file_count",
            "findings",
            "refuted_candidates",
            "unverified_candidates",
            "coverage_notes",
            "dropped_coverage"
          ],
          "properties" => %{
            "verdict" => %{"type" => "string", "enum" => ["pass", "findings", "inconclusive"]},
            "scanned_file_count" => %{"type" => "integer", "minimum" => 0},
            "findings" => %{
              "type" => "array",
              "items" => %{
                "type" => "object",
                "additionalProperties" => false,
                "required" => [
                  "id",
                  "merged_ids",
                  "rule_id",
                  "severity",
                  "adjudication",
                  "file",
                  "line",
                  "issue",
                  "evidence",
                  "failure_scenario",
                  "recommended_fix"
                ],
                "properties" => %{
                  "id" => %{"type" => "string"},
                  "merged_ids" => %{"type" => "array", "items" => %{"type" => "string"}},
                  "rule_id" => %{"type" => "string"},
                  "severity" => %{"type" => "string", "enum" => ["low", "medium", "high", "critical"]},
                  "adjudication" => %{"type" => "string", "enum" => ["confirmed", "plausible"]},
                  "file" => %{"type" => "string"},
                  "line" => %{"type" => "integer", "minimum" => 1},
                  "issue" => %{"type" => "string"},
                  "evidence" => %{"type" => "string"},
                  "failure_scenario" => %{"type" => "string"},
                  "recommended_fix" => %{"type" => "string"}
                }
              }
            },
            "refuted_candidates" => %{
              "type" => "array",
              "items" => %{
                "type" => "object",
                "additionalProperties" => false,
                "required" => ["id", "reason", "evidence"],
                "properties" => %{
                  "id" => %{"type" => "string"},
                  "reason" => %{"type" => "string"},
                  "evidence" => %{"type" => "string"}
                }
              }
            },
            "unverified_candidates" => %{
              "type" => "array",
              "items" => %{
                "type" => "object",
                "additionalProperties" => false,
                "required" => ["id", "reason"],
                "properties" => %{
                  "id" => %{"type" => "string"},
                  "reason" => %{"type" => "string"}
                }
              }
            },
            "coverage_notes" => %{"type" => "array", "items" => %{"type" => "string"}},
            "dropped_coverage" => %{"type" => "array", "items" => %{"type" => "string"}}
          }
        },
        retries: 1
      )
  )

  emit(~P"""
  # Staff-Level Elixir Adversarial Scan

  **Verdict:** <%= path(@final, "/verdict") %>
  **Scanned file count:** <%= path(@final, "/scanned_file_count") %>
  **Surviving finding count:** <%= count(@final, "/findings") %>
  **Refuted candidate count:** <%= count(@final, "/refuted_candidates") %>
  **Unverified candidate count:** <%= count(@final, "/unverified_candidates") %>

  ## Surviving findings

  <%= numbered_findings(@final, "/findings") %>

  ## Refuted candidates

  <%= numbered_findings(@final, "/refuted_candidates") %>

  ## Unverified candidates

  <%= numbered_findings(@final, "/unverified_candidates") %>

  ## Coverage notes

  <%= path(@final, "/coverage_notes") %>

  ## Dropped or unproven coverage

  <%= path(@final, "/dropped_coverage") %>

  _Structured collections use the workflow's deterministic text renderer; this terminal is not JSON._
  """)
end
