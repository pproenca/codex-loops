workflow "release-readiness-panel" do
  phase("Independent release gates")
  log("running four read-only release-readiness reviews against the current candidate")

  fanout width: 4, bind: :checks, max_concurrency: 4 do
    lanes([
      [
        agent(
          """
          Act as the correctness and build gate for the release candidate in the current workspace.

          Establish scope from the current branch, `git status --short`, the diff against its merge base,
          package manifests, CI definitions, and release scripts. Run only deterministic, non-destructive
          checks that are justified by those files. Inspect test selection, build reproducibility, generated
          artifacts, version consistency, and whether the changed behavior has focused regression coverage.

          Evidence rules:
          - Cite repository-relative paths and 1-based lines for source claims; use line 0 only for command output.
          - Record the exact commands run and distinguish a command not run from a command that passed.
          - Treat an unverified required check, unexplained dirty generated output, or a failing deterministic
            check as a blocker. Do not infer success from the presence of a script or CI job.
          - Keep warnings separate from blockers and name a concrete verification for every required action.

          Safety boundary: this is a read-only gate. Do not edit files, install dependencies, publish packages,
          change Git state, contact production services, or use credentials. If a check would require any of
          those actions, report it as an unknown or required action instead of performing it.

          Set `area` to `correctness-build`. Set `verdict` to `ready`, `conditional`, or `block`; `ready`
          requires direct evidence for every release-critical assertion. Confidence is from 0 to 1 and must
          fall when evidence is missing.
          """,
          label: "release:correctness-build",
          schema: %{
            "type" => "object",
            "additionalProperties" => false,
            "required" => [
              "area",
              "verdict",
              "confidence",
              "evidence",
              "blockers",
              "warnings",
              "required_actions",
              "commands_run",
              "unknowns"
            ],
            "properties" => %{
              "area" => %{"type" => "string"},
              "verdict" => %{"type" => "string", "enum" => ["ready", "conditional", "block"]},
              "confidence" => %{"type" => "number", "minimum" => 0, "maximum" => 1},
              "evidence" => %{
                "type" => "array",
                "items" => %{
                  "type" => "object",
                  "additionalProperties" => false,
                  "required" => ["path", "line", "claim", "observation"],
                  "properties" => %{
                    "path" => %{"type" => "string"},
                    "line" => %{"type" => "integer", "minimum" => 0},
                    "claim" => %{"type" => "string"},
                    "observation" => %{"type" => "string"}
                  }
                }
              },
              "blockers" => %{
                "type" => "array",
                "items" => %{
                  "type" => "object",
                  "additionalProperties" => false,
                  "required" => ["id", "issue", "fix"],
                  "properties" => %{
                    "id" => %{"type" => "string"},
                    "issue" => %{"type" => "string"},
                    "fix" => %{"type" => "string"}
                  }
                }
              },
              "warnings" => %{
                "type" => "array",
                "items" => %{
                  "type" => "object",
                  "additionalProperties" => false,
                  "required" => ["id", "issue", "fix"],
                  "properties" => %{
                    "id" => %{"type" => "string"},
                    "issue" => %{"type" => "string"},
                    "fix" => %{"type" => "string"}
                  }
                }
              },
              "required_actions" => %{
                "type" => "array",
                "items" => %{
                  "type" => "object",
                  "additionalProperties" => false,
                  "required" => ["id", "issue", "fix"],
                  "properties" => %{
                    "id" => %{"type" => "string"},
                    "issue" => %{"type" => "string"},
                    "fix" => %{"type" => "string"}
                  }
                }
              },
              "commands_run" => %{"type" => "array", "items" => %{"type" => "string"}},
              "unknowns" => %{"type" => "array", "items" => %{"type" => "string"}}
            }
          },
          retries: 1
        )
      ],
      [
        agent(
          """
          Act as the security and supply-chain gate for the release candidate in the current workspace.

          Read the actual diff, dependency and lock files, authentication and authorization boundaries,
          secret-handling paths, network clients, parsers, deserializers, installer or updater code, and the
          CI/release trust chain touched by the change. Look for expanded privileges, untrusted input crossing
          a boundary without validation, credential leakage, unsafe defaults, dependency provenance gaps,
          and release steps that can publish an unintended artifact.

          Evidence rules:
          - Cite repository-relative paths and 1-based lines for source claims; use line 0 only for command output.
          - Separate demonstrated vulnerabilities from plausible threats and from missing evidence.
          - A credible exploit path, credential exposure, unsigned/unverified artifact path, or missing required
            authorization check is a blocker. Do not label speculative style concerns as security blockers.
          - Record every read-only command run and give a concrete verification for every required action.

          Safety boundary: do not modify files, install or upgrade packages, run active exploits, access secrets,
          make network requests, publish artifacts, or touch production. Use static evidence and safe local checks;
          report any higher-risk verification as an unknown or required action.

          Set `area` to `security-supply-chain`. Set `verdict` to `ready`, `conditional`, or `block` based on
          evidence. Confidence is from 0 to 1 and must reflect both scope coverage and evidence quality.
          """,
          label: "release:security-supply-chain",
          schema: %{
            "type" => "object",
            "additionalProperties" => false,
            "required" => [
              "area",
              "verdict",
              "confidence",
              "evidence",
              "blockers",
              "warnings",
              "required_actions",
              "commands_run",
              "unknowns"
            ],
            "properties" => %{
              "area" => %{"type" => "string"},
              "verdict" => %{"type" => "string", "enum" => ["ready", "conditional", "block"]},
              "confidence" => %{"type" => "number", "minimum" => 0, "maximum" => 1},
              "evidence" => %{
                "type" => "array",
                "items" => %{
                  "type" => "object",
                  "additionalProperties" => false,
                  "required" => ["path", "line", "claim", "observation"],
                  "properties" => %{
                    "path" => %{"type" => "string"},
                    "line" => %{"type" => "integer", "minimum" => 0},
                    "claim" => %{"type" => "string"},
                    "observation" => %{"type" => "string"}
                  }
                }
              },
              "blockers" => %{
                "type" => "array",
                "items" => %{
                  "type" => "object",
                  "additionalProperties" => false,
                  "required" => ["id", "issue", "fix"],
                  "properties" => %{
                    "id" => %{"type" => "string"},
                    "issue" => %{"type" => "string"},
                    "fix" => %{"type" => "string"}
                  }
                }
              },
              "warnings" => %{
                "type" => "array",
                "items" => %{
                  "type" => "object",
                  "additionalProperties" => false,
                  "required" => ["id", "issue", "fix"],
                  "properties" => %{
                    "id" => %{"type" => "string"},
                    "issue" => %{"type" => "string"},
                    "fix" => %{"type" => "string"}
                  }
                }
              },
              "required_actions" => %{
                "type" => "array",
                "items" => %{
                  "type" => "object",
                  "additionalProperties" => false,
                  "required" => ["id", "issue", "fix"],
                  "properties" => %{
                    "id" => %{"type" => "string"},
                    "issue" => %{"type" => "string"},
                    "fix" => %{"type" => "string"}
                  }
                }
              },
              "commands_run" => %{"type" => "array", "items" => %{"type" => "string"}},
              "unknowns" => %{"type" => "array", "items" => %{"type" => "string"}}
            }
          },
          retries: 1
        )
      ],
      [
        agent(
          """
          Act as the runtime, persistence, and compatibility gate for the release candidate.

          Inspect runtime supervision and lifecycle behavior, durable state transitions, database or file-format
          migrations, public API and CLI contracts, configuration defaults, rollback compatibility, concurrency,
          retry and timeout behavior, and restart or resume semantics touched by the candidate. Use the repository's
          tests and operational documentation as claims to verify, not as proof by themselves.

          Evidence rules:
          - Cite repository-relative paths and 1-based lines for source claims; use line 0 only for command output.
          - Trace at least one success path and the important failure/restart path for every changed durable effect.
          - Treat irreversible migration without a proven recovery path, incompatible persisted state, broken
            rollback, data-loss risk, or an unbounded runtime behavior as a blocker.
          - Record exact read-only or test commands; distinguish untested platform assumptions as unknowns.

          Safety boundary: do not modify committed files, mutate real journals or databases, run migrations against
          non-ephemeral data, stop services, or change configuration. Use disposable test fixtures only when the
          existing test command already owns them; otherwise describe the required verification without running it.

          Set `area` to `runtime-persistence-compatibility`. Use `ready`, `conditional`, or `block` for the verdict.
          Confidence is from 0 to 1 and must be reduced for untested recovery, migration, or rollback claims.
          """,
          label: "release:runtime-compatibility",
          schema: %{
            "type" => "object",
            "additionalProperties" => false,
            "required" => [
              "area",
              "verdict",
              "confidence",
              "evidence",
              "blockers",
              "warnings",
              "required_actions",
              "commands_run",
              "unknowns"
            ],
            "properties" => %{
              "area" => %{"type" => "string"},
              "verdict" => %{"type" => "string", "enum" => ["ready", "conditional", "block"]},
              "confidence" => %{"type" => "number", "minimum" => 0, "maximum" => 1},
              "evidence" => %{
                "type" => "array",
                "items" => %{
                  "type" => "object",
                  "additionalProperties" => false,
                  "required" => ["path", "line", "claim", "observation"],
                  "properties" => %{
                    "path" => %{"type" => "string"},
                    "line" => %{"type" => "integer", "minimum" => 0},
                    "claim" => %{"type" => "string"},
                    "observation" => %{"type" => "string"}
                  }
                }
              },
              "blockers" => %{
                "type" => "array",
                "items" => %{
                  "type" => "object",
                  "additionalProperties" => false,
                  "required" => ["id", "issue", "fix"],
                  "properties" => %{
                    "id" => %{"type" => "string"},
                    "issue" => %{"type" => "string"},
                    "fix" => %{"type" => "string"}
                  }
                }
              },
              "warnings" => %{
                "type" => "array",
                "items" => %{
                  "type" => "object",
                  "additionalProperties" => false,
                  "required" => ["id", "issue", "fix"],
                  "properties" => %{
                    "id" => %{"type" => "string"},
                    "issue" => %{"type" => "string"},
                    "fix" => %{"type" => "string"}
                  }
                }
              },
              "required_actions" => %{
                "type" => "array",
                "items" => %{
                  "type" => "object",
                  "additionalProperties" => false,
                  "required" => ["id", "issue", "fix"],
                  "properties" => %{
                    "id" => %{"type" => "string"},
                    "issue" => %{"type" => "string"},
                    "fix" => %{"type" => "string"}
                  }
                }
              },
              "commands_run" => %{"type" => "array", "items" => %{"type" => "string"}},
              "unknowns" => %{"type" => "array", "items" => %{"type" => "string"}}
            }
          },
          retries: 1
        )
      ],
      [
        agent(
          """
          Act as the operations, observability, and rollback gate for the release candidate.

          Inspect deployment and packaging instructions, health checks, telemetry, logs, alerts, support runbooks,
          configuration rollout, upgrade and rollback commands, operator-visible errors, and release notes. Confirm
          that an operator can detect a bad rollout, contain impact, identify the running version, and recover without
          relying on undocumented knowledge. Check that user-visible behavior and compatibility changes are documented.

          Evidence rules:
          - Cite repository-relative paths and 1-based lines for source claims; use line 0 only for command output.
          - Treat docs as assertions and compare them with executable scripts, flags, defaults, and emitted telemetry.
          - Missing detection for a high-impact failure, no actionable rollback path, ambiguous artifact/version
            identity, or a release instruction that can destroy data is a blocker.
          - Record exact safe commands and turn every gap into a concrete action with a verification step.

          Safety boundary: do not deploy, publish, stop processes, mutate service state, rotate credentials, or execute
          rollback against real data. Do not modify the workspace. Limit work to inspection and safe local help/version
          commands; describe invasive checks rather than performing them.

          Set `area` to `operations-observability-rollback`. Use `ready`, `conditional`, or `block` for the verdict.
          Confidence is from 0 to 1 and must fall when operational claims cannot be tested locally.
          """,
          label: "release:operations-rollback",
          schema: %{
            "type" => "object",
            "additionalProperties" => false,
            "required" => [
              "area",
              "verdict",
              "confidence",
              "evidence",
              "blockers",
              "warnings",
              "required_actions",
              "commands_run",
              "unknowns"
            ],
            "properties" => %{
              "area" => %{"type" => "string"},
              "verdict" => %{"type" => "string", "enum" => ["ready", "conditional", "block"]},
              "confidence" => %{"type" => "number", "minimum" => 0, "maximum" => 1},
              "evidence" => %{
                "type" => "array",
                "items" => %{
                  "type" => "object",
                  "additionalProperties" => false,
                  "required" => ["path", "line", "claim", "observation"],
                  "properties" => %{
                    "path" => %{"type" => "string"},
                    "line" => %{"type" => "integer", "minimum" => 0},
                    "claim" => %{"type" => "string"},
                    "observation" => %{"type" => "string"}
                  }
                }
              },
              "blockers" => %{
                "type" => "array",
                "items" => %{
                  "type" => "object",
                  "additionalProperties" => false,
                  "required" => ["id", "issue", "fix"],
                  "properties" => %{
                    "id" => %{"type" => "string"},
                    "issue" => %{"type" => "string"},
                    "fix" => %{"type" => "string"}
                  }
                }
              },
              "warnings" => %{
                "type" => "array",
                "items" => %{
                  "type" => "object",
                  "additionalProperties" => false,
                  "required" => ["id", "issue", "fix"],
                  "properties" => %{
                    "id" => %{"type" => "string"},
                    "issue" => %{"type" => "string"},
                    "fix" => %{"type" => "string"}
                  }
                }
              },
              "required_actions" => %{
                "type" => "array",
                "items" => %{
                  "type" => "object",
                  "additionalProperties" => false,
                  "required" => ["id", "issue", "fix"],
                  "properties" => %{
                    "id" => %{"type" => "string"},
                    "issue" => %{"type" => "string"},
                    "fix" => %{"type" => "string"}
                  }
                }
              },
              "commands_run" => %{"type" => "array", "items" => %{"type" => "string"}},
              "unknowns" => %{"type" => "array", "items" => %{"type" => "string"}}
            }
          },
          retries: 1
        )
      ]
    ])
  end

  phase("Release decision")

  let(
    :summary =
      agent(
        ~P"""
        Produce the final release decision from the four ordered gate reports below.

        Gate reports:
        <%= @checks %>

        Re-open cited repository evidence when a claim is consequential or reports conflict. Do not average away
        a blocker. The final decision must be `block` if any credible blocker remains, `conditional` if there are
        required pre-release actions or material unknowns, and `ready` only when every gate is ready with adequate
        evidence. Deduplicate findings by cause, preserve dissent in the rationale, and never convert an unknown
        into a pass. Every blocking or warning finding needs a stable id, a precise issue, and a verifiable fix.

        This aggregation is read-only. Do not repair the candidate, publish anything, or run invasive checks.
        """,
        label: "release:aggregate-decision",
        schema: %{
          "type" => "object",
          "additionalProperties" => false,
          "required" => [
            "release_decision",
            "rationale",
            "blocking_findings",
            "warning_findings",
            "required_checks",
            "rollback_conditions",
            "evidence_gaps"
          ],
          "properties" => %{
            "release_decision" => %{
              "type" => "string",
              "enum" => ["ready", "conditional", "block"]
            },
            "rationale" => %{"type" => "string"},
            "blocking_findings" => %{
              "type" => "array",
              "items" => %{
                "type" => "object",
                "additionalProperties" => false,
                "required" => ["id", "issue", "fix"],
                "properties" => %{
                  "id" => %{"type" => "string"},
                  "issue" => %{"type" => "string"},
                  "fix" => %{"type" => "string"}
                }
              }
            },
            "warning_findings" => %{
              "type" => "array",
              "items" => %{
                "type" => "object",
                "additionalProperties" => false,
                "required" => ["id", "issue", "fix"],
                "properties" => %{
                  "id" => %{"type" => "string"},
                  "issue" => %{"type" => "string"},
                  "fix" => %{"type" => "string"}
                }
              }
            },
            "required_checks" => %{"type" => "array", "items" => %{"type" => "string"}},
            "rollback_conditions" => %{"type" => "array", "items" => %{"type" => "string"}},
            "evidence_gaps" => %{"type" => "array", "items" => %{"type" => "string"}}
          }
        },
        retries: 1
      )
  )

  emit(~P"""
  # Release Readiness Decision

  **Decision:** <%= path(@summary, "/release_decision") %>

  <%= path(@summary, "/rationale") %>

  ## Blocking findings (<%= count(@summary, "/blocking_findings") %>)

  <%= numbered_findings(@summary, "/blocking_findings") %>

  ## Warnings (<%= count(@summary, "/warning_findings") %>)

  <%= numbered_findings(@summary, "/warning_findings") %>

  ## Required checks

  <%= path(@summary, "/required_checks") %>

  ## Rollback conditions

  <%= path(@summary, "/rollback_conditions") %>

  ## Evidence gaps

  <%= path(@summary, "/evidence_gaps") %>
  """)
end
