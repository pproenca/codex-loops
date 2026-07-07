defmodule WorkflowDslSpecWorkflow do
  use Workflow

  workflow "workflow-dsl-spec" do
    phase "Ground truth"

    agent """
    Extract GROUND TRUTH for the "spec-structure" area.

    Read the current repository state and identify only the existing facts that
    matter to the workflow DSL specification.
    """

    phase "Draft"

    agent """
    SURGICAL EDIT — DO NOT REWRITE SPEC.md.

    Draft the smallest insertion that explains the workflow DSL structure while
    preserving surrounding document language and section ordering.
    """

    phase "Converge"

    parallel [
      agent("""
      LENS: NON-DESTRUCTIVENESS (the safety guard)

      Review the proposed SPEC.md edit for accidental rewrites, deleted intent,
      or changes outside the intended section.
      """),
      agent("""
      Resolve these final cold-read defects with TARGETED edits to §10 only.

      Keep the review focused on precise wording and missing acceptance criteria.
      """)
    ]

    phase "Finalize"

    agent """
    Finalize the SPEC.md §10 insertion for HUMAN REVIEW — do NOT commit anything.

    Produce the final patch summary and unresolved questions, if any.
    """

    return :ready_for_human_review
  end
end
