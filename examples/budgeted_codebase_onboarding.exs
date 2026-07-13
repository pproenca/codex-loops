# Runtime requirement: start this workflow with a finite budget of at least 4_000.
# `budget_slices` chooses a scout count from remaining budget; it does not allocate a per-lane quota.
workflow "budgeted-codebase-onboarding" do
  phase("Independent repository scouts")
  log("scaling independent whole-codebase reconnaissance to the finite run budget")

  fanout width: budget_slices(per: 4_000, max: 6),
         bind: :work,
         max_concurrency: 4,
         on_zero: :fail do
    agent(
      """
      Independently build an evidence-backed orientation to the entire current codebase for an engineer who must
      make a safe first change.

      This is a repeated whole-codebase scout. You receive no lane index, file partition, or implicit specialty;
      do not claim that you own one slice. Survey the repository yourself and follow the evidence that appears most
      consequential. Begin with tracked-file and top-level structure, then read authoritative project guidance,
      build and dependency manifests, executable entry points, core domain modules, persistence and external-effect
      boundaries, tests, CI, release and operations paths, and recent architectural decisions when present.

      Explain the system through concrete flows rather than directory names: trace at least one normal request or
      command from entry point to durable/output effect, and one failure or recovery path. Identify which component
      owns each important invariant, where concurrency or retries occur, how state is persisted, what the complete
      deterministic test gate is, and where a novice change is most likely to violate a contract. Distinguish facts
      proved by files or command output from interpretations and open questions.

      Evidence and safety rules:
      - Cite repository-relative paths and 1-based lines; use line 0 only for command output.
      - Record exact read-only commands. Prefer targeted help, listing, and test-discovery commands over broad builds.
      - Do not edit files, install dependencies, run formatters, mutate databases or journals, start or stop services,
        contact production, make network requests, or change Git state.
      - Never invent an architecture from naming conventions. If generated, vendored, or unavailable material blocks
        a conclusion, preserve the gap explicitly.
      - Risks must describe a plausible failure, cite its evidence, and give the safest verification or mitigation.

      The result should let another engineer find the right files, understand the runtime and data flow, run the
      appropriate checks, and know what remains uncertain without rereading the whole repository immediately.
      """,
      label: "onboarding:whole-codebase-scout",
      schema: %{
        "type" => "object",
        "additionalProperties" => false,
        "required" => [
          "orientation",
          "system_map",
          "entrypoints",
          "critical_flows",
          "test_and_build_commands",
          "risks",
          "evidence",
          "unknowns"
        ],
        "properties" => %{
          "orientation" => %{"type" => "string"},
          "system_map" => %{
            "type" => "array",
            "items" => %{
              "type" => "object",
              "additionalProperties" => false,
              "required" => ["component", "responsibility", "owned_invariants", "paths"],
              "properties" => %{
                "component" => %{"type" => "string"},
                "responsibility" => %{"type" => "string"},
                "owned_invariants" => %{"type" => "array", "items" => %{"type" => "string"}},
                "paths" => %{"type" => "array", "items" => %{"type" => "string"}}
              }
            }
          },
          "entrypoints" => %{
            "type" => "array",
            "items" => %{
              "type" => "object",
              "additionalProperties" => false,
              "required" => ["name", "path", "purpose"],
              "properties" => %{
                "name" => %{"type" => "string"},
                "path" => %{"type" => "string"},
                "purpose" => %{"type" => "string"}
              }
            }
          },
          "critical_flows" => %{
            "type" => "array",
            "items" => %{
              "type" => "object",
              "additionalProperties" => false,
              "required" => ["name", "steps", "failure_or_recovery"],
              "properties" => %{
                "name" => %{"type" => "string"},
                "steps" => %{"type" => "array", "items" => %{"type" => "string"}},
                "failure_or_recovery" => %{"type" => "string"}
              }
            }
          },
          "test_and_build_commands" => %{
            "type" => "array",
            "items" => %{
              "type" => "object",
              "additionalProperties" => false,
              "required" => ["command", "purpose", "evidence_path"],
              "properties" => %{
                "command" => %{"type" => "string"},
                "purpose" => %{"type" => "string"},
                "evidence_path" => %{"type" => "string"}
              }
            }
          },
          "risks" => %{
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
          "evidence" => %{
            "type" => "array",
            "items" => %{
              "type" => "object",
              "additionalProperties" => false,
              "required" => ["path", "line", "claim"],
              "properties" => %{
                "path" => %{"type" => "string"},
                "line" => %{"type" => "integer", "minimum" => 0},
                "claim" => %{"type" => "string"}
              }
            }
          },
          "unknowns" => %{"type" => "array", "items" => %{"type" => "string"}}
        }
      },
      retries: 1
    )
  end

  phase("Onboarding synthesis")

  let(
    :summary =
      agent(
        ~P"""
        Synthesize a trustworthy engineering onboarding guide from these independent whole-codebase scout reports:

        <%= @work %>

        Reconcile reports against repository evidence. Merge duplicate facts, retain useful independent paths,
        and resolve disagreements by reopening cited files or using safe read-only commands. Do not use majority
        vote as proof. Mark a claim as uncertain when no report provides verifiable evidence, and omit generic
        advice that is not specific to this repository.

        The guide must explain: what the product does; the smallest accurate component map; a normal end-to-end
        flow; a failure/recovery flow; ownership of durable state and important invariants; how to build and test;
        a safe first-change playbook; high-risk areas; and unanswered questions. Commands must be copied from or
        verified against repository-owned configuration. Cite repository-relative paths throughout.

        This turn is read-only. Do not edit documentation, run broad mutation-prone commands, start services,
        install dependencies, or fill evidence gaps by guessing.
        """,
        label: "onboarding:synthesize-guide",
        schema: %{
          "type" => "object",
          "additionalProperties" => false,
          "required" => [
            "product_summary",
            "component_map",
            "normal_flow",
            "failure_and_recovery_flow",
            "state_and_invariants",
            "build_and_test",
            "first_change_playbook",
            "risk_findings",
            "open_questions"
          ],
          "properties" => %{
            "product_summary" => %{"type" => "string"},
            "component_map" => %{"type" => "array", "items" => %{"type" => "string"}},
            "normal_flow" => %{"type" => "array", "items" => %{"type" => "string"}},
            "failure_and_recovery_flow" => %{
              "type" => "array",
              "items" => %{"type" => "string"}
            },
            "state_and_invariants" => %{
              "type" => "array",
              "items" => %{"type" => "string"}
            },
            "build_and_test" => %{"type" => "array", "items" => %{"type" => "string"}},
            "first_change_playbook" => %{
              "type" => "array",
              "items" => %{"type" => "string"}
            },
            "risk_findings" => %{
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
            "open_questions" => %{"type" => "array", "items" => %{"type" => "string"}}
          }
        },
        retries: 1
      )
  )

  emit(~P"""
  # Codebase Onboarding Guide

  ## Product

  <%= path(@summary, "/product_summary") %>

  ## Component map

  <%= path(@summary, "/component_map") %>

  ## Normal flow

  <%= path(@summary, "/normal_flow") %>

  ## Failure and recovery flow

  <%= path(@summary, "/failure_and_recovery_flow") %>

  ## State and invariants

  <%= path(@summary, "/state_and_invariants") %>

  ## Build and test

  <%= path(@summary, "/build_and_test") %>

  ## Safe first-change playbook

  <%= path(@summary, "/first_change_playbook") %>

  ## Risks (<%= count(@summary, "/risk_findings") %>)

  <%= numbered_findings(@summary, "/risk_findings") %>

  ## Open questions

  <%= path(@summary, "/open_questions") %>
  """)
end
