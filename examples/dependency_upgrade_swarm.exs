workflow "dependency-upgrade-swarm" do
  phase("Upgrade inventory")
  log("building a strict, evidence-backed inventory before choosing reviewer width")

  let(
    :rows =
      agent(
        """
        Build the authoritative dependency-upgrade inventory for the current workspace without changing it.

        Candidate scope is deliberately closed: include only dependency version changes visible in the current
        working-tree or branch diff, plus upgrades explicitly named in a repository-root
        `DEPENDENCY_UPGRADE.md` when that file exists. Inspect every relevant manifest and lockfile needed to
        prove current and target versions. Do not query registries, guess a latest version, or turn unrelated
        outdated packages into candidates.

        For every candidate, assign a stable id derived from ecosystem, manifest path, and dependency name.
        Explain why it is in scope; distinguish direct from transitive dependencies; list affected runtime,
        build, test, packaging, and deployment surfaces; cite exact repository evidence; and list deterministic
        commands that would validate the upgrade. If a target is requested but cannot be proven from repository
        evidence, preserve it as an unknown rather than inventing a version.

        `scope_basis` means: `working-tree` for diff-only scope, `plan-file` for plan-only scope, `both` when both
        sources contribute, or `none` when neither source names an upgrade. Return an empty `items` list for
        `none`. Paths are repository-relative. This turn is read-only: do not edit manifests or lockfiles,
        install packages, update caches, make network requests, or run migration scripts.
        """,
        label: "dependencies:inventory",
        schema: %{
          "type" => "object",
          "additionalProperties" => false,
          "required" => ["scope_basis", "baseline", "ecosystems", "items", "constraints", "unknowns"],
          "properties" => %{
            "scope_basis" => %{
              "type" => "string",
              "enum" => ["working-tree", "plan-file", "both", "none"]
            },
            "baseline" => %{"type" => "string"},
            "ecosystems" => %{"type" => "array", "items" => %{"type" => "string"}},
            "items" => %{
              "type" => "array",
              "items" => %{
                "type" => "object",
                "additionalProperties" => false,
                "required" => [
                  "id",
                  "dependency",
                  "ecosystem",
                  "current_version",
                  "target_version",
                  "manifest_path",
                  "lockfile_path",
                  "direct",
                  "reason",
                  "affected_surfaces",
                  "evidence",
                  "validation_commands"
                ],
                "properties" => %{
                  "id" => %{"type" => "string"},
                  "dependency" => %{"type" => "string"},
                  "ecosystem" => %{"type" => "string"},
                  "current_version" => %{"type" => "string"},
                  "target_version" => %{"type" => "string"},
                  "manifest_path" => %{"type" => "string"},
                  "lockfile_path" => %{"type" => "string"},
                  "direct" => %{"type" => "boolean"},
                  "reason" => %{"type" => "string"},
                  "affected_surfaces" => %{
                    "type" => "array",
                    "items" => %{"type" => "string"}
                  },
                  "evidence" => %{
                    "type" => "array",
                    "items" => %{
                      "type" => "object",
                      "additionalProperties" => false,
                      "required" => ["path", "line", "observation"],
                      "properties" => %{
                        "path" => %{"type" => "string"},
                        "line" => %{"type" => "integer", "minimum" => 1},
                        "observation" => %{"type" => "string"}
                      }
                    }
                  },
                  "validation_commands" => %{
                    "type" => "array",
                    "items" => %{"type" => "string"}
                  }
                }
              }
            },
            "constraints" => %{"type" => "array", "items" => %{"type" => "string"}},
            "unknowns" => %{"type" => "array", "items" => %{"type" => "string"}}
          }
        },
        retries: 1
      )
  )

  phase("Independent whole-inventory review")

  fanout width: path_count(:rows, "/items", max: 6),
         bind: :checks,
         max_concurrency: 4,
         on_zero: :complete do
    agent(
      """
      Independently audit the complete dependency-upgrade scope in the current workspace.

      This repeated fanout lane is intentionally not assigned one dependency: it receives no item value, lane
      index, or implicit partition. Reconstruct and review the whole inventory from the current diff, manifests,
      lockfiles, and repository-root `DEPENDENCY_UPGRADE.md` if present. The number of lanes scales with inventory
      size only to obtain multiple independent whole-scope judgments.

      Analyze compatibility notes encoded in source and tests, feature and optional-dependency changes, transitive
      resolution, supported toolchain or runtime ranges, lockfile integrity, build and release effects, migration
      requirements, rollback behavior, and whether validation reaches each affected surface. Search for removed or
      changed APIs actually used by the repository. Do not claim an upstream fact that is absent from checked-in
      evidence; record it as an unknown requiring authoritative release notes.

      Verdict meanings: `approve` means no blocking issue and enough local evidence to run the proposed validation;
      `changes` means the plan needs a correction or additional proof; `block` means a credible compatibility,
      integrity, security, or data-loss risk makes the upgrade unsafe. Findings require stable ids, concrete local
      evidence, and a verifiable fix. Coverage must name what was inspected, not merely say `all dependencies`.

      Safety boundary: read only. Do not edit manifests or lockfiles, install or update dependencies, contact
      registries, execute migrations, clear caches, or mutate Git state. Safe local inspection commands are allowed;
      list exactly what ran and report every unavailable invasive check as an unknown.
      """,
      label: "dependencies:whole-inventory-review",
      schema: %{
        "type" => "object",
        "additionalProperties" => false,
        "required" => ["verdict", "coverage", "findings", "commands_run", "unknowns"],
        "properties" => %{
          "verdict" => %{"type" => "string", "enum" => ["approve", "changes", "block"]},
          "coverage" => %{"type" => "array", "items" => %{"type" => "string"}},
          "findings" => %{
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
  end

  phase("Upgrade decision")

  let(
    :summary =
      agent(
        ~P"""
        Produce an actionable dependency-upgrade decision from the authoritative inventory and the ordered list
        of independent whole-inventory reviews.

        Inventory:
        <%= @rows %>

        Independent reviews:
        <%= @checks %>

        If the inventory is empty, return `no-upgrades` and explain the closed scope rather than fabricating work.
        Otherwise, reconcile findings by evidence, not vote count. A single credible blocker must survive even if
        other reviews missed it. Deduplicate the same root cause, preserve unresolved upstream facts as evidence
        gaps, and order the execution plan so reversible checks precede manifest changes and migrations. Every
        finding needs a stable id, precise issue, and verifiable fix. Do not edit the workspace in this turn.
        """,
        label: "dependencies:aggregate-decision",
        schema: %{
          "type" => "object",
          "additionalProperties" => false,
          "required" => [
            "decision",
            "inventory_count",
            "rationale",
            "blocking_findings",
            "required_changes",
            "validation_plan",
            "rollback_plan",
            "evidence_gaps"
          ],
          "properties" => %{
            "decision" => %{
              "type" => "string",
              "enum" => ["no-upgrades", "proceed", "proceed-after-changes", "block"]
            },
            "inventory_count" => %{"type" => "integer", "minimum" => 0},
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
            "required_changes" => %{
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
            "validation_plan" => %{"type" => "array", "items" => %{"type" => "string"}},
            "rollback_plan" => %{"type" => "array", "items" => %{"type" => "string"}},
            "evidence_gaps" => %{"type" => "array", "items" => %{"type" => "string"}}
          }
        },
        retries: 1
      )
  )

  emit(~P"""
  # Dependency Upgrade Decision

  **Decision:** <%= path(@summary, "/decision") %>
  **Candidates inventoried:** <%= path(@summary, "/inventory_count") %>

  <%= path(@summary, "/rationale") %>

  ## Blocking findings (<%= count(@summary, "/blocking_findings") %>)

  <%= numbered_findings(@summary, "/blocking_findings") %>

  ## Required changes (<%= count(@summary, "/required_changes") %>)

  <%= numbered_findings(@summary, "/required_changes") %>

  ## Validation plan

  <%= path(@summary, "/validation_plan") %>

  ## Rollback plan

  <%= path(@summary, "/rollback_plan") %>

  ## Evidence gaps

  <%= path(@summary, "/evidence_gaps") %>
  """)
end
