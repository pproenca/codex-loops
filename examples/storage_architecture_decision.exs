workflow "storage-architecture-decision" do
  phase("Challenge decision premises")
  log("Recording independent premise checks and scoring projections before a separate synthesis")

  # Verify panels are observational: their verdicts are journaled for the operator, but no verdict
  # is passed into synthesize or later agents and no failed premise automatically halts this workflow.
  verify(
    """
    The service needs one authoritative durable store for transactional state, must survive process and host restarts,
    and cannot accept a design whose correctness depends on best-effort cache or PubSub delivery.
    """,
    lenses: [:correctness, :runtime, :operations],
    threshold: :unanimous
  )

  verify(
    """
    The operating team can support backups, restore drills, schema evolution, capacity alerts, and rollback procedures
    for the selected storage system without introducing a second always-on platform team.
    """,
    lenses: [:safety, :operations, :effort],
    threshold: :majority
  )

  phase("Record an observational option score")

  # Judge is also observational. Its winner and scores belong to the journal/status projection; the
  # independently bound synthesis below sees only its own literal inputs and must reach its own conclusion.
  judge(
    [
      "PostgreSQL as the transactional system of record, with explicit migrations, connection pooling, backups, and read replicas only when measured load requires them.",
      "SQLite owned by one service instance, with serialized writes, WAL-mode operational discipline, replicated volume snapshots, and an explicit single-writer deployment constraint.",
      "A managed key-value database with application-enforced invariants, conditional writes, denormalized access paths, point-in-time recovery, and no cross-item transaction assumptions."
    ],
    by: [:risk, :effort],
    pick: :min_score
  )

  phase("Synthesize from explicit facts")

  let(
    :summary =
      synthesize(
        [
          %{
            "decision" => "Choose the primary durable store for a small team operating one regional service.",
            "workload" =>
              "Moderate write volume, relational entities, multi-record invariants, background jobs, and audit history.",
            "availability" =>
              "Brief maintenance windows are acceptable; silent data loss and ambiguous committed state are not.",
            "growth" =>
              "Start simple, but preserve a credible path to higher read volume and additional service instances."
          },
          %{
            "constraints" => [
              "The journal or database is the source of truth; notifications are refresh hints only.",
              "Creating durable work and recording its intent should be atomic where possible.",
              "Backups are not a recovery strategy until restore time and data integrity are exercised.",
              "Every option needs a migration, rollback, observability, and ownership story.",
              "Prefer the least operational machinery that still makes invariants explicit and testable."
            ]
          },
          %{
            "candidates" => [
              "PostgreSQL transactional system of record",
              "Single-writer SQLite with WAL and snapshot discipline",
              "Managed key-value database with conditional writes"
            ]
          }
        ],
        """
        Write a self-contained architecture decision record from these literal facts. Independently compare all candidates;
        you do not receive and must not infer any verify verdict or judge winner from earlier workflow nodes. State assumptions,
        choose or defer a recommendation, explain rejected alternatives, define the data ownership and transaction model, and
        specify migration, backup/restore, observability, capacity, and rollback proof. Separate known facts from questions that
        require measurement. Prefer reversible validation before irreversible adoption.
        """
      )
  )

  phase("Red-team the independent decision")

  let(
    :final =
      agent(
        ~P"""
        Red-team the independently synthesized storage decision below and produce the final decision record.

        Synthesized ADR:
        <%= @summary %>

        Important workflow boundary: the earlier verify and judge projections are not inputs here. Do not claim their premises
        passed, do not claim a judge winner, and do not retrofit their unseen scores into the rationale. An operator can inspect
        those observational projections separately in workflow status.

        Stress the ADR against transaction anomalies, duplicate delivery, partial failure, restart and restore behavior, schema
        migration, connection or lock contention, capacity cliffs, regional outage, security boundaries, cost surprises, and
        operator workload. Preserve a recommendation only if its invariants and recovery evidence are credible. Otherwise choose
        a pilot or defer decision, and name the experiment that resolves uncertainty.

        Every key risk needs a stable id, concrete issue, evidence or assumption, and practical mitigation. Validation experiments
        require an observable success signal and a stop signal. Do not modify the repository; this workflow creates a decision
        artifact, not an implementation.
        """,
        label: "red-team:storage-decision",
        schema: %{
          "type" => "object",
          "additionalProperties" => false,
          "required" => [
            "decision_status",
            "recommendation",
            "decision_rationale",
            "key_risks",
            "validation_plan",
            "operating_model",
            "rollback_triggers",
            "dissent"
          ],
          "properties" => %{
            "decision_status" => %{
              "type" => "string",
              "enum" => ["adopt", "pilot", "defer"]
            },
            "recommendation" => %{"type" => "string"},
            "decision_rationale" => %{"type" => "string"},
            "key_risks" => %{
              "type" => "array",
              "items" => %{
                "type" => "object",
                "additionalProperties" => false,
                "required" => ["id", "evidence", "issue", "fix"],
                "properties" => %{
                  "id" => %{"type" => "string"},
                  "evidence" => %{"type" => "string"},
                  "issue" => %{"type" => "string"},
                  "fix" => %{"type" => "string"}
                }
              }
            },
            "validation_plan" => %{
              "type" => "array",
              "items" => %{
                "type" => "object",
                "additionalProperties" => false,
                "required" => ["experiment", "success_signal", "stop_signal"],
                "properties" => %{
                  "experiment" => %{"type" => "string"},
                  "success_signal" => %{"type" => "string"},
                  "stop_signal" => %{"type" => "string"}
                }
              }
            },
            "operating_model" => %{
              "type" => "array",
              "items" => %{"type" => "string"}
            },
            "rollback_triggers" => %{
              "type" => "array",
              "items" => %{"type" => "string"}
            },
            "dissent" => %{"type" => "string"}
          }
        },
        retries: 1
      )
  )

  emit(~P"""
  # Storage Architecture Decision

  **Decision status:** <%= path(@final, "/decision_status") %>
  **Key risk count:** <%= count(@final, "/key_risks") %>
  **Validation experiment count:** <%= count(@final, "/validation_plan") %>

  ## Recommendation

  <%= path(@final, "/recommendation") %>

  ## Rationale

  <%= path(@final, "/decision_rationale") %>

  ## Key risks and mitigations

  <%= numbered_findings(@final, "/key_risks") %>

  ## Validation plan

  <%= path(@final, "/validation_plan") %>

  ## Operating model

  <%= path(@final, "/operating_model") %>

  ## Rollback triggers

  <%= path(@final, "/rollback_triggers") %>

  ## Dissent and unresolved questions

  <%= path(@final, "/dissent") %>

  ## Independent synthesis excerpt

  <%= truncate(@summary, 2500) %>

  _Verify and judge outcomes are intentionally absent from this report; inspect their journal projections separately._
  """)
end
