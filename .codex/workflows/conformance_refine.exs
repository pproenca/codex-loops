workflow "conformance-refine" do
  phase("refine")

  refine(agent("Draft an inline artifact."),
    reviewers: [
      reviewer(:spec, "Review the inline artifact."),
      reviewer(:runtime, "Review its runtime behavior.")
    ],
    revise_with: agent("Repair the inline artifact."),
    until: :unanimous,
    max_rounds: 1
  )

  let(:draft = agent("Draft a bound artifact."))

  let(
    :final =
      refine(:draft,
        reviewers: [
          reviewer(:correctness, "Review correctness."),
          reviewer(:operations, "Review operations.")
        ],
        revise_with: agent("Repair the bound artifact."),
        until: :unanimous,
        max_rounds: 1,
        gates: [
          cold_read: [
            reviewer: reviewer(:cold_read, "Cold-read the converged artifact."),
            when: path_non_empty("/openFindings")
          ],
          repair_when: path_non_empty("/coldRead/openFindings"),
          halt_when: path_count("/finalOpenDefects") > 0
        ]
      )
  )

  emit_result(:final)
end
