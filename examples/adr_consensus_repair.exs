workflow "adr-consensus-repair" do
  phase("review and repair")

  log("reviewing docs/adr/PROPOSED.md through independent correctness, safety, and operations lanes")

  loop max_iterations: 4, on_exhausted: :fail do
    fanout width: 3, bind: :checks, max_concurrency: 3 do
      lanes([
        [
          agent(
            """
            Read `docs/adr/PROPOSED.md` as a correctness reviewer. This is a read-only review: do not
            edit the ADR or any other file.

            Check that the decision, context, alternatives, constraints, and consequences form a
            coherent argument; that claims about the current repository cite concrete files or
            commands; that compatibility and migration assumptions are implementable; and that the
            verification plan could falsify the proposal. Treat missing acceptance criteria, circular
            reasoning, contradicted repository facts, and an unexecutable migration as blocking.

            Set `approved` to true only when there are no blocking findings. Every finding must carry
            a stable id, a precise issue, direct evidence with an ADR section or repository path, and
            an actionable repair. Include the evidence inspected even when approving.
            """,
            label: "review:adr-correctness",
            schema: %{
              "type" => "object",
              "additionalProperties" => false,
              "properties" => %{
                "approved" => %{"type" => "boolean"},
                "blocking_findings" => %{
                  "type" => "array",
                  "items" => %{
                    "type" => "object",
                    "additionalProperties" => false,
                    "properties" => %{
                      "id" => %{"type" => "string"},
                      "issue" => %{"type" => "string"},
                      "evidence" => %{"type" => "string"},
                      "repair" => %{"type" => "string"}
                    },
                    "required" => ["id", "issue", "evidence", "repair"]
                  }
                },
                "evidence_reviewed" => %{
                  "type" => "array",
                  "items" => %{"type" => "string"}
                }
              },
              "required" => ["approved", "blocking_findings", "evidence_reviewed"]
            },
            retries: 1
          )
        ],
        [
          agent(
            """
            Read `docs/adr/PROPOSED.md` as a safety reviewer. This is a read-only review: do not edit
            the ADR or any other file.

            Threat-model the proposed change across data loss, privilege boundaries, secret handling,
            destructive commands, concurrency, partial failure, rollback, and compatibility with
            existing persisted state. Verify that risky operations have bounded scope, observable
            failure modes, and a recovery path. Treat an irreversible migration without a proven
            backup/rollback strategy, a widened trust boundary without enforcement, or an unbounded
            failure blast radius as blocking.

            Set `approved` to true only when there are no blocking findings. Every finding must carry
            a stable id, a precise issue, direct evidence with an ADR section or repository path, and
            an actionable repair. Include the evidence inspected even when approving.
            """,
            label: "review:adr-safety",
            schema: %{
              "type" => "object",
              "additionalProperties" => false,
              "properties" => %{
                "approved" => %{"type" => "boolean"},
                "blocking_findings" => %{
                  "type" => "array",
                  "items" => %{
                    "type" => "object",
                    "additionalProperties" => false,
                    "properties" => %{
                      "id" => %{"type" => "string"},
                      "issue" => %{"type" => "string"},
                      "evidence" => %{"type" => "string"},
                      "repair" => %{"type" => "string"}
                    },
                    "required" => ["id", "issue", "evidence", "repair"]
                  }
                },
                "evidence_reviewed" => %{
                  "type" => "array",
                  "items" => %{"type" => "string"}
                }
              },
              "required" => ["approved", "blocking_findings", "evidence_reviewed"]
            },
            retries: 1
          )
        ],
        [
          agent(
            """
            Read `docs/adr/PROPOSED.md` as an operations reviewer. This is a read-only review: do not
            edit the ADR or any other file.

            Check deployability, configuration ownership, upgrade and rollback sequencing, monitoring,
            alerting, capacity limits, incident diagnostics, and the exact operator commands needed to
            prove health. Compare the proposal with the repository's actual build, test, release, and
            runtime entry points. Treat an unobservable rollout, ambiguous ownership, missing rollback
            trigger, or acceptance gate that cannot run in CI or staging as blocking.

            Set `approved` to true only when there are no blocking findings. Every finding must carry
            a stable id, a precise issue, direct evidence with an ADR section or repository path, and
            an actionable repair. Include the evidence inspected even when approving.
            """,
            label: "review:adr-operations",
            schema: %{
              "type" => "object",
              "additionalProperties" => false,
              "properties" => %{
                "approved" => %{"type" => "boolean"},
                "blocking_findings" => %{
                  "type" => "array",
                  "items" => %{
                    "type" => "object",
                    "additionalProperties" => false,
                    "properties" => %{
                      "id" => %{"type" => "string"},
                      "issue" => %{"type" => "string"},
                      "evidence" => %{"type" => "string"},
                      "repair" => %{"type" => "string"}
                    },
                    "required" => ["id", "issue", "evidence", "repair"]
                  }
                },
                "evidence_reviewed" => %{
                  "type" => "array",
                  "items" => %{"type" => "string"}
                }
              },
              "required" => ["approved", "blocking_findings", "evidence_reviewed"]
            },
            retries: 1
          )
        ]
      ])
    end

    until(agree(:checks, path: "/approved", equals: true, threshold: :all))

    agent(
      """
      Consensus was not reached for `docs/adr/PROPOSED.md`. Repair that proposed ADR and no other
      file. You do not receive the review lanes' result objects, so re-audit the ADR directly against
      the same correctness, safety, and operations criteria before editing.

      First read the full ADR and the repository sources, tests, build commands, and operational docs
      needed to verify its claims. Make the smallest coherent edit that resolves concrete gaps: clarify
      the decision and rejected alternatives, replace unsupported claims with cited repository facts,
      pin migration/rollback steps, add measurable acceptance gates, and describe bounded failure and
      recovery behavior. Preserve valid content and the repository's ADR style.

      Write only `docs/adr/PROPOSED.md`. Do not create, rename, or delete files; do not modify code,
      tests, configuration, lockfiles, generated artifacts, or git state. You may run read-only
      inspection and validation commands. If the proposed ADR is absent or the required repair would
      exceed that one-file scope, make no edits and report the blocker accurately.
      """,
      label: "repair:proposed-adr-only",
      schema: %{
        "type" => "object",
        "additionalProperties" => false,
        "properties" => %{
          "edited" => %{"type" => "boolean"},
          "path" => %{"type" => "string"},
          "changes" => %{"type" => "array", "items" => %{"type" => "string"}},
          "evidence_checked" => %{
            "type" => "array",
            "items" => %{"type" => "string"}
          },
          "blocker" => %{"type" => "string"}
        },
        "required" => ["edited", "path", "changes", "evidence_checked", "blocker"]
      },
      retries: 1
    )
  end

  return("ADR consensus reached for docs/adr/PROPOSED.md")
end
