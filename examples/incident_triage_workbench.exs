workflow "incident-triage-workbench" do
  phase("Parallel incident investigation")
  log("collecting four disjoint evidence dossiers before causal synthesis")

  parallel(
    [
      agent(
        """
        Investigate the incident timeline and write one evidence dossier to exactly:
        `.codex/workflow-artifacts/incident-triage/timeline.md`.

        Treat repository-root `INCIDENT.md` as the incident brief. Read only local evidence it explicitly points to,
        such as captured logs, traces, screenshots, command transcripts, or exported metrics. Normalize every useful
        time to the timezone stated by the source; when a source has no timezone, preserve the raw timestamp and mark
        it ambiguous. Build a sequence from the last known-good observation through onset, detection, interventions,
        and current state. Distinguish observed events from inferred ordering and identify missing intervals.

        The dossier must contain: scope and source inventory; a table with timestamp, source, observed event, and
        confidence; contradictions; missing evidence; and the most time-sensitive next collection steps. Quote only
        short identifying fragments and cite the local path plus line or record identifier for every event.

        Safety boundary: create the parent directory if needed and overwrite only `timeline.md`. Do not edit any other
        file, alter logs, start or stop services, query production, use credentials, make network requests, or run a
        command that mutates application state. If `INCIDENT.md` or its necessary local evidence is absent, still
        overwrite `timeline.md` with a clearly marked BLOCKED dossier explaining exactly what is missing.

        Return a receipt for this dossier. `evidence_count` is the number of independently cited observations, not
        the number of files opened. `status` is `complete`, `partial`, or `blocked`.
        """,
        label: "incident:timeline",
        schema: %{
          "type" => "object",
          "additionalProperties" => false,
          "required" => ["artifact_path", "status", "evidence_count", "highest_risk", "unknowns"],
          "properties" => %{
            "artifact_path" => %{"type" => "string"},
            "status" => %{"type" => "string", "enum" => ["complete", "partial", "blocked"]},
            "evidence_count" => %{"type" => "integer", "minimum" => 0},
            "highest_risk" => %{"type" => "string"},
            "unknowns" => %{"type" => "array", "items" => %{"type" => "string"}}
          }
        },
        retries: 1
      ),
      agent(
        """
        Investigate recent code, configuration, dependency, and deployment changes and write one evidence dossier
        to exactly `.codex/workflow-artifacts/incident-triage/changes.md`.

        Use repository-root `INCIDENT.md` to bound the incident window and affected behavior. Inspect local Git
        history and diffs, release metadata, configuration defaults, migrations, feature flags represented in the
        repository, dependency or lockfile changes, and deployment scripts. Identify changes that can plausibly
        affect the observed symptom, then trace the relevant execution path. For each candidate change record its
        identifier, changed path and line, mechanism linking it to the symptom, evidence for and against, and a safe
        falsification step. Correlation in time alone is not causation.

        The dossier must contain: examined baseline and window; candidate changes ranked by evidentiary support;
        ruled-out changes with reasons; compatibility or rollback constraints; gaps; and safe next checks. Do not
        invent deployment history that is not present in local evidence.

        Safety boundary: create the parent directory if needed and overwrite only `changes.md`. Do not edit source,
        configuration, manifests, locks, migrations, or Git state; do not revert, build, install, deploy, use network
        access, or contact production. If the brief or baseline is unavailable, overwrite `changes.md` with a BLOCKED
        dossier stating which facts are required rather than widening the time window without authority.

        Return a receipt for this dossier. `evidence_count` counts concrete path/commit/line citations. `status` is
        `complete`, `partial`, or `blocked`.
        """,
        label: "incident:changes",
        schema: %{
          "type" => "object",
          "additionalProperties" => false,
          "required" => ["artifact_path", "status", "evidence_count", "highest_risk", "unknowns"],
          "properties" => %{
            "artifact_path" => %{"type" => "string"},
            "status" => %{"type" => "string", "enum" => ["complete", "partial", "blocked"]},
            "evidence_count" => %{"type" => "integer", "minimum" => 0},
            "highest_risk" => %{"type" => "string"},
            "unknowns" => %{"type" => "array", "items" => %{"type" => "string"}}
          }
        },
        retries: 1
      ),
      agent(
        """
        Investigate runtime behavior, failure mechanics, and observability and write one evidence dossier to exactly:
        `.codex/workflow-artifacts/incident-triage/runtime.md`.

        Begin with repository-root `INCIDENT.md`. Read the runtime architecture, process or service lifecycle,
        supervision and restart policy, queues and backpressure, retry and timeout behavior, persistence boundaries,
        health checks, logs, metrics, traces, and operational runbooks relevant to the symptom. Use only captured
        local telemetry named by the brief. Trace a normal path and the suspected failure/recovery path, noting where
        the available signals can or cannot distinguish overload, dependency failure, corrupted state, deadlock,
        crash loop, or operator intervention.

        The dossier must contain: runtime map; symptom-to-signal correlation; failure hypotheses with evidence for
        and against; observability blind spots; restart/retry amplification risks; and non-invasive next checks.
        Treat absence of a log or metric as missing evidence unless the code proves that signal must always be emitted.

        Safety boundary: create the parent directory if needed and overwrite only `runtime.md`. Do not modify runtime
        configuration, journals, databases, or source; do not start, stop, restart, attach to, or send traffic to any
        service; do not query production, use credentials, or make network requests. If local telemetry is missing,
        write a PARTIAL or BLOCKED dossier and specify the minimum safe collection required.

        Return a receipt for this dossier. `evidence_count` counts independently cited code, config, or telemetry
        observations. `status` is `complete`, `partial`, or `blocked`.
        """,
        label: "incident:runtime",
        schema: %{
          "type" => "object",
          "additionalProperties" => false,
          "required" => ["artifact_path", "status", "evidence_count", "highest_risk", "unknowns"],
          "properties" => %{
            "artifact_path" => %{"type" => "string"},
            "status" => %{"type" => "string", "enum" => ["complete", "partial", "blocked"]},
            "evidence_count" => %{"type" => "integer", "minimum" => 0},
            "highest_risk" => %{"type" => "string"},
            "unknowns" => %{"type" => "array", "items" => %{"type" => "string"}}
          }
        },
        retries: 1
      ),
      agent(
        """
        Investigate data integrity, customer impact, containment safety, and recovery constraints and write one
        evidence dossier to exactly `.codex/workflow-artifacts/incident-triage/safety.md`.

        Use repository-root `INCIDENT.md` to establish affected operations, users, data, and time window. Inspect
        local schemas, invariants, transaction boundaries, idempotency and delivery semantics, authorization and
        privacy boundaries, migrations, backup or recovery documentation, and captured evidence named by the brief.
        Identify what data could be missing, duplicated, stale, disclosed, or irreversibly changed. Separate confirmed
        impact, bounded worst case, and unknown exposure. Evaluate proposed containment or recovery actions for data
        loss, double execution, privacy, rollback, and auditability risk.

        The dossier must contain: impact bounds and derivation; protected invariants; potential integrity or security
        failures; safe containment options; actions that require human authorization; recovery preconditions and
        verification; and evidence gaps. Do not assert that data is safe merely because no corruption report exists.

        Safety boundary: create the parent directory if needed and overwrite only `safety.md`. Do not inspect secrets
        or personal data, query or mutate real databases, replay jobs, run migrations, restore backups, change access,
        contact users, or connect to production. Do not edit repository files. If safe local evidence cannot bound
        impact, write a PARTIAL or BLOCKED dossier with explicit escalation and evidence requirements.

        Return a receipt for this dossier. `evidence_count` counts independently cited invariant, code, or captured
        evidence observations. `status` is `complete`, `partial`, or `blocked`.
        """,
        label: "incident:safety-and-data",
        schema: %{
          "type" => "object",
          "additionalProperties" => false,
          "required" => ["artifact_path", "status", "evidence_count", "highest_risk", "unknowns"],
          "properties" => %{
            "artifact_path" => %{"type" => "string"},
            "status" => %{"type" => "string", "enum" => ["complete", "partial", "blocked"]},
            "evidence_count" => %{"type" => "integer", "minimum" => 0},
            "highest_risk" => %{"type" => "string"},
            "unknowns" => %{"type" => "array", "items" => %{"type" => "string"}}
          }
        },
        retries: 1
      )
    ],
    max_concurrency: 4
  )

  phase("Incident synthesis")

  let(
    :summary =
      agent(
        """
        Produce an evidence-controlled incident triage report from repository-root `INCIDENT.md` and exactly these
        post-barrier investigator artifacts:

        - `.codex/workflow-artifacts/incident-triage/timeline.md`
        - `.codex/workflow-artifacts/incident-triage/changes.md`
        - `.codex/workflow-artifacts/incident-triage/runtime.md`
        - `.codex/workflow-artifacts/incident-triage/safety.md`

        Verify that every artifact exists, names the current incident scope, and contains cited evidence before
        relying on it. A missing, blocked, contradictory, or apparently stale dossier is an evidence gap, never a
        silent pass. Re-open cited local sources for consequential claims and contradictions. Establish facts first;
        rank hypotheses separately with evidence for, evidence against, and a safe falsification step. Do not call a
        hypothesis root cause until the available evidence establishes the causal mechanism.

        Containment actions must reduce immediate harm without destroying diagnostic evidence or causing duplicate
        effects. Recovery actions must state authorization, prerequisites, rollback or abort conditions, and a
        post-action verification. Put production access, customer communication, credential use, data repair,
        migration, replay, or destructive commands behind explicit human authorization. If the evidence cannot
        bound safety, set incident status to `blocked` and say what must be collected or decided.

        This aggregation is read-only. Do not modify the four dossiers or any other file, contact production, or
        execute containment or recovery actions.
        """,
        label: "incident:aggregate-report",
        schema: %{
          "type" => "object",
          "additionalProperties" => false,
          "required" => [
            "incident_status",
            "executive_summary",
            "timeline",
            "established_facts",
            "leading_hypotheses",
            "containment_actions",
            "recovery_actions",
            "verification_plan",
            "evidence_gaps",
            "artifact_receipts"
          ],
          "properties" => %{
            "incident_status" => %{
              "type" => "string",
              "enum" => ["contained", "active", "monitoring", "blocked", "unknown"]
            },
            "executive_summary" => %{"type" => "string"},
            "timeline" => %{"type" => "array", "items" => %{"type" => "string"}},
            "established_facts" => %{
              "type" => "array",
              "items" => %{
                "type" => "object",
                "additionalProperties" => false,
                "required" => ["source", "statement"],
                "properties" => %{
                  "source" => %{"type" => "string"},
                  "statement" => %{"type" => "string"}
                }
              }
            },
            "leading_hypotheses" => %{
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
            "containment_actions" => %{
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
            "recovery_actions" => %{
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
            "verification_plan" => %{"type" => "array", "items" => %{"type" => "string"}},
            "evidence_gaps" => %{"type" => "array", "items" => %{"type" => "string"}},
            "artifact_receipts" => %{
              "type" => "array",
              "items" => %{
                "type" => "object",
                "additionalProperties" => false,
                "required" => ["path", "status"],
                "properties" => %{
                  "path" => %{"type" => "string"},
                  "status" => %{"type" => "string"}
                }
              }
            }
          }
        },
        retries: 1
      )
  )

  emit(~P"""
  # Incident Triage Report

  **Status:** <%= path(@summary, "/incident_status") %>

  <%= path(@summary, "/executive_summary") %>

  ## Timeline

  <%= path(@summary, "/timeline") %>

  ## Established facts

  <%= path(@summary, "/established_facts") %>

  ## Leading hypotheses (<%= count(@summary, "/leading_hypotheses") %>)

  <%= numbered_findings(@summary, "/leading_hypotheses") %>

  ## Containment actions

  <%= numbered_findings(@summary, "/containment_actions") %>

  ## Recovery actions

  <%= numbered_findings(@summary, "/recovery_actions") %>

  ## Verification plan

  <%= path(@summary, "/verification_plan") %>

  ## Evidence gaps

  <%= path(@summary, "/evidence_gaps") %>

  ## Investigator artifacts

  <%= path(@summary, "/artifact_receipts") %>
  """)
end
