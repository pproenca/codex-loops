defmodule Workflow.Catalog.ShipFeature do
  @moduledoc """
  Catalog workflow: the **flagship** end-to-end orchestration — take a feature slice
  from scoping all the way to shipped, exercising nearly the whole combinator
  vocabulary in one coherent multi-phase run.

  It is deliberately the same *shape* as the pipeline that built this runtime —
  investigate, implement, harden, adversarially review, choose an integration
  strategy, then summarize — but expressed entirely in the closed DSL:

    * `parallel` — fan investigation across independent lanes, then barrier.
    * `pipeline` — drive the implementation through ordered layers, per item.
    * `while_budget` — harden against failing tests until the budget runs low.
    * `until_dry` + `collect` — harvest edge cases into a declared accumulator
      until two rounds surface nothing new (deduped by `:id`).
    * `verify` — submit the result to a perspective-diverse review panel; it
      survives only when a majority of lenses confirm.
    * `judge` — score the integration strategies and pick the lowest-risk.
    * `fan_out width: budget_slices(per:)` — scale the acceptance suite across
      whatever budget remains.
    * `synthesize` — fold the phases into a ship report.
    * `let` + `refine` + `emit_result` — bind the ship report, run a gated
      adversarial refinement panel, and return the structured refine result.

  The agent prompts are written the way a real orchestrator writes them —
  contract-shaped, with an explicit task, a structured-output contract, a
  follow-through policy, and a verification loop — because the point of the demo is
  to show orchestrating *real* agent work, not toy one-liners. Every prompt is a
  compile-time literal (no interpolation), so every node stays inert and the whole
  run is deterministic, resumable, and a pure fold of its journal.

  The one thing this *cannot* express is arbitrary imperative control flow
  (`if not green, break`; mutate a local variable and branch on it). The DSL now
  permits the narrow, replay-safe form of value flow: `let` binds already-journaled
  outputs, `~P` renders them deterministically, and `refine`/`emit_result` preserve
  the final review record as structured public data. Declarative equivalents carry
  the rest of the intent — a fail-closed `verify` panel stands in for "reject on
  violation", and a bounded `until_dry` loop stands in for "repair until settled".
  """
  use Workflow

  workflow "ship-feature" do
    log(
      "shipping one feature slice end to end: scope -> implement -> harden -> review -> integrate"
    )

    phase("scope")

    parallel([
      agent("""
      <task>
      Map every module, function, and boundary this feature slice will touch. Work
      only from the current tree; do not propose changes yet.
      </task>
      <structured_output_contract>
      Return: (1) the call graph of affected modules, (2) the seams where new code
      will attach, ranked by how few of them the change can go through, (3) any
      module whose contract the slice would have to widen.
      </structured_output_contract>
      <action_safety>
      Read-only. Touch nothing. Prefer the highest existing seam over a new one.
      </action_safety>
      """),
      agent("""
      <task>
      Draft the acceptance test plan for this slice: the externally observable
      behaviors that must hold when it is done.
      </task>
      <structured_output_contract>
      Return a numbered list of acceptance checks, each phrased as an observable
      input -> output at the highest seam, plus the single demo that proves the
      slice end to end.
      </structured_output_contract>
      <default_follow_through_policy>
      Test external behavior only, never implementation detail. If a behavior can't
      be observed at a seam, say so rather than reaching inside.
      </default_follow_through_policy>
      """),
      agent("""
      <task>
      Enumerate the non-negotiable design constraints this slice must not violate —
      the invariants that make the change correct rather than merely compiling.
      </task>
      <structured_output_contract>
      Return each constraint as: the invariant, the failure it prevents, and the
      cheapest check that would catch a violation.
      </structured_output_contract>
      """)
    ])

    phase("implement")

    pipeline(
      ["schema", "core", "interface", "tests"],
      [
        agent("""
        <task>
        Implement this layer of the slice end to end. Preserve all behavior outside
        the stated scope. Build on the layers already committed before you.
        </task>
        <structured_output_contract>
        Return: summary of the work, the files touched, the verification you ran,
        and any residual risk or follow-up.
        </structured_output_contract>
        <default_follow_through_policy>
        Default to the most reasonable low-risk interpretation and keep going. Only
        stop to ask when a missing detail changes correctness, safety, or an
        irreversible action.
        </default_follow_through_policy>
        <verification_loop>
        Before finalizing, verify the layer against the acceptance plan and the
        design constraints. If a check fails, fix it or report the exact blocker.
        </verification_loop>
        <action_safety>
        Keep changes tightly scoped. No unrelated refactors, renames, or cleanup.
        </action_safety>
        """),
        agent("""
        <task>
        Wire this layer to the adjacent layers so the seam is exercised end to end,
        not just unit-green in isolation.
        </task>
        <verification_loop>
        Drive the real seam and observe the behavior — do not settle for a passing
        unit test. If the integration surfaces a gap, fix it or name the blocker.
        </verification_loop>
        """)
      ]
    )

    phase("harden")

    while_budget reserve: 10 do
      agent("""
      <task>
      Reproduce and fix exactly one failing acceptance test for this slice, then
      stop. One test per iteration keeps each fix small and independently reviewable.
      </task>
      <verification_loop>
      Reproduce the failure first and capture it, apply the minimal fix, then re-run
      to confirm the failure is gone and nothing else regressed.
      </verification_loop>
      <action_safety>
      Fix only the one failure in hand. Resist widening scope across the suite.
      </action_safety>
      """)
    end

    phase("harvest-edge-cases")

    until_dry rounds: 2, seen_by: [:id] do
      agent(
        """
        <task>
        Surface any remaining untested edge cases for this slice that the acceptance
        plan does not yet cover — boundary values, concurrency interleavings, resume
        and crash points, malformed input.
        </task>
        <structured_output_contract>
        Return a JSON array of edge cases, each an object with a stable `id`, the
        scenario, and the observable behavior it should exhibit. Return an empty
        array when you find nothing new.
        </structured_output_contract>
        """,
        schema: %{"type" => "array"}
      )

      collect(into: :edge_cases)
    end

    phase("review")

    verify(
      """
      <task>
      Adversarially review the completed slice against its non-negotiable design
      constraints and acceptance plan. Assume it is wrong until proven otherwise;
      grep the real source rather than trusting the summary.
      </task>
      <structured_output_contract>
      Cast a single fail-closed verdict: does the slice satisfy every design
      constraint AND every acceptance check? A "yes" requires evidence; any
      unproven claim is a "no".
      </structured_output_contract>
      """,
      lenses: [:correctness, :idiom, :constraints],
      threshold: :majority
    )

    phase("integrate")

    judge(
      [
        "merge straight to main once review passes",
        "stack a reviewed PR and gate on CI",
        "ship behind a feature flag and roll out gradually"
      ],
      by: [:risk, :speed],
      pick: :min_score
    )

    phase("scale-out")

    fan_out width: budget_slices(per: 50) do
      agent("""
      <task>
      Run one shard of the full acceptance suite for the shipped slice and report
      only this shard's results. Shards run concurrently; keep your report scoped to
      the tests you were assigned.
      </task>
      <structured_output_contract>
      Return: shard identifier, tests run, failures with their reproduction, and a
      pass/fail verdict for the shard.
      </structured_output_contract>
      """)
    end

    phase("report")

    let(
      :ship_report =
        synthesize(
          ["scope", "implement", "harden", "review", "integrate"],
          """
          Fold the phase outputs into a ship report for a human reviewer: what changed
          and why, what was verified and how (name the seams and the demo), the edge
          cases harvested, the chosen integration strategy with its trade-off, and the
          residual risk that survives to production.
          """
        )
    )

    phase("release-gate")

    let(
      :reviewed_report =
        refine(:ship_report,
          reviewers: [
            reviewer(
              :release_readiness,
              """
              Review the ship report for release readiness. Return approved=true only when
              the report names the shipped behavior, verification evidence, and residual
              risk clearly enough for a human reviewer to trust it.
              """,
              adapter: :findings_v1
            ),
            reviewer(
              :operability,
              """
              Review the ship report from an operations lens. Return approved=true only
              when rollback, observability, and support risk are either addressed or
              explicitly out of scope with justification.
              """,
              adapter: :findings_v1
            )
          ],
          revise_with:
            agent("""
            Repair the ship report using every blocking finding. Preserve true statements
            about the implementation and verification; do not invent evidence.
            """),
          until: :unanimous,
          max_rounds: 2,
          on_non_convergence: :accept_current,
          gates: [
            cold_read: [
              reviewer:
                reviewer(
                  :cold_read,
                  """
                  Cold-read the final ship report as if you did not participate in the
                  work. Return approved=true only if the report is understandable,
                  evidence-backed, and actionable without hidden context.
                  """,
                  adapter: :findings_v1
                ),
              when: path_exists("")
            ],
            repair_when: path_non_empty("/coldRead/openFindings"),
            halt_when: path_non_empty("/roleFailures")
          ]
        )
    )

    emit_result(:reviewed_report)
  end
end
