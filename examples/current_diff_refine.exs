workflow "current-diff-refine" do
  phase("Implement within the current diff")
  log("Improving the current change while preserving unrelated user work and requiring adversarial convergence")

  let(
    :draft =
      agent(
        """
        Improve the repository's current diff as a narrowly scoped implementer.

        Establish scope before editing:
        - Read the repository guidance, `git status --short`, the staged and unstaged diffs, and relevant nearby tests.
        - Treat every pre-existing modification and untracked file as user-owned work.
        - Work only in files already participating in the current change, plus the smallest directly necessary tests or
          documentation needed to prove that same behavior. Do not broaden the feature or perform opportunistic cleanup.

        Mutation safety:
        - Never reset, checkout, restore, clean, stage, commit, amend, rebase, or delete unrelated files.
        - Do not overwrite unexplained edits. If safe integration is impossible, leave the affected file unchanged and
          record the blocker in the artifact.
        - Avoid generated files and dependency updates unless the current diff explicitly requires them.

        Implementation and proof:
        - Trace the changed behavior through its callers, error paths, persistence or concurrency boundaries, and public contract.
        - Fix concrete defects you can demonstrate without changing the author's apparent intent.
        - Run the narrowest relevant formatter, compile, lint, and tests. Never report a command as passing unless it ran.
        - Re-read the final diff to catch scope drift and accidental deletion.

        The artifact is a durable handoff: enumerate exact files changed, why each edit was necessary, commands and outcomes,
        unresolved risks, and any reason work was intentionally left untouched.
        """,
        label: "implement:scoped-current-diff",
        schema: %{
          "type" => "object",
          "additionalProperties" => false,
          "required" => ["artifact"],
          "properties" => %{
            "artifact" => %{"type" => "string"}
          }
        },
        retries: 1
      )
  )

  phase("Converge under independent review")

  let(
    :final =
      refine(
        :draft,
        reviewers: [
          reviewer(
            :correctness,
            """
            Review the current workspace and diff for behavioral correctness. Re-read every changed implementation and its
            callers; do not trust the artifact's claims without source evidence. Look for wrong invariants, boundary errors,
            incomplete error handling, incompatible API behavior, missing regression tests, and assertions that do not prove
            the claimed outcome. This is read-only: never modify files. A blocking finding must cite a precise file/location,
            explain a reproducible failure or unproved contract, and propose the smallest intent-preserving fix. Approve only
            when the scoped change is coherent and its critical behavior is actually demonstrated.
            """,
            adapter: :findings_v1
          ),
          reviewer(
            :safety,
            """
            Adversarially audit change safety. Compare `git status` and the complete diff against the stated scope; detect
            unrelated rewrites, lost user edits, destructive commands, secret exposure, unsafe input trust, authorization
            gaps, and migrations or data operations without a recovery path. Inspect evidence directly and remain read-only.
            Mark scope drift or a plausible destructive/security failure as blocking, with exact evidence and a concrete
            non-destructive remedy. Approval means the change preserves user work and fails safely at every relevant boundary.
            """,
            adapter: :findings_v1
          ),
          reviewer(
            :runtime,
            """
            Review runtime behavior of the current diff against the repository's actual architecture. Inspect concurrency,
            process or task ownership, timeouts, retries, idempotency, resource bounds, persistence ordering, error propagation,
            performance-sensitive paths, and resume or restart behavior where relevant. Do not edit. Reject speculative style
            preferences; report only evidence-backed defects or missing proof that could change production behavior. Every
            blocking finding needs a stable id, source location, failure mechanism, and bounded repair.
            """,
            adapter: :findings_v1
          ),
          reviewer(
            :operations,
            """
            Assess whether an operator can ship, observe, and recover this exact change. Verify test commands and outcomes,
            configuration compatibility, release and migration ordering, useful diagnostics, rollback constraints, and the
            accuracy of documentation or handoff notes. Inspect the live workspace read-only. Treat an unrun critical gate,
            silent failure mode, irreversible rollout, or misleading success claim as blocking. Give exact evidence and the
            smallest operational fix; approve only when residual risk is explicit and proportionate.
            """,
            adapter: :findings_v1
          )
        ],
        revise_with:
          agent("""
          Resolve every blocking refine finding against the live current diff, using source evidence rather than blindly
          following reviewer prose. Re-read repository guidance, status, and both staged and unstaged diffs before each repair.

          Mutate only files already in the current change plus the smallest directly necessary tests or documentation. Preserve
          unrelated user work byte-for-byte. Never reset, checkout, restore, clean, stage, commit, amend, rebase, or delete
          unexplained files. If reviewer requests conflict or a safe fix needs authority outside this scope, do not guess:
          leave that area unchanged and document the blocker.

          Run the narrowest relevant verification after edits and inspect the resulting diff for scope drift. Return a complete
          updated artifact describing exact changes, evidence, commands and outcomes, remaining risks, and unresolved blockers.
          Do not claim convergence merely because prose was revised; the workspace itself must satisfy the findings.
          """),
        until: :unanimous,
        max_rounds: 3,
        on_non_convergence: :fail,
        max_concurrency: 4,
        gates: [
          cold_read: [
            reviewer:
              reviewer(
                :invariants,
                """
                Perform a final cold read with no reliance on earlier reviewer conclusions. Inspect repository guidance, current
                status, the complete diff, changed call paths, and the reported verification evidence. Remain read-only. Look for
                one class of defect that consensus reviews often miss: a violated invariant, stale assumption, unhandled recovery
                path, accidental scope expansion, or claim not supported by an executed check. Return blocking findings only for
                concrete release-relevant defects, each with exact evidence and a bounded fix. Approve when a fresh maintainer
                could safely understand, verify, and ship the current change. This is a fail-closed final gate: do not edit the
                workspace. Any blocking finding must halt this run so a new run reviews the eventual repair from the beginning.
                """,
                adapter: :findings_v1
              ),
            when: path_non_empty("/artifact")
          ],
          halt_when: path_non_empty("/coldRead/openFindings")
        ]
      )
  )

  emit_result(:final)
end
