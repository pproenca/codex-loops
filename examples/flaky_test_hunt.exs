workflow "flaky-test-hunt" do
  phase("bounded discovery")

  log(
    "collecting reproducible flaky-test candidates until the search is dry, sufficiently broad, or near its budget reserve"
  )

  loop max_iterations: 12,
       until:
         any([
           dry(rounds: 2, seen_by: [:id]),
           count(:items) >= 12,
           budget_remaining() <= 4_000
         ]),
       on_exhausted: :accept_current do
    agent(
      """
      Perform one focused, read-only flaky-test discovery pass in the current repository.

      Start by inspecting the test layout, CI configuration, recent working-tree changes, and any
      existing retry, quarantine, timeout, random-seed, or race-related annotations. Choose a small
      suspicious test surface and run targeted repetitions with the repository's native test command.
      Preserve exact commands, seeds, environment flags, observed pass/fail counts, and the smallest
      concrete evidence that distinguishes a real intermittent failure from a deterministic failure.

      Return only candidates substantiated during this pass. Return an empty array when this pass adds
      no credible candidate. Give every candidate a stable `id` derived from its test path/name and
      failure signature so repeated discoveries deduplicate across rounds. Do not modify source files,
      snapshots, test configuration, lockfiles, generated files, or git state. Do not broaden into the
      full suite when a targeted command can answer the question.

      A candidate is credible only when its evidence states how many runs were attempted, how many
      failed, the exact failure signature, and at least one plausible nondeterministic mechanism. Mark
      confidence conservatively; a suspicion without an observed failure is `low` confidence.
      """,
      label: "discover:reproducible-flakes",
      schema: %{
        "type" => "array",
        "items" => %{
          "type" => "object",
          "additionalProperties" => false,
          "properties" => %{
            "id" => %{"type" => "string"},
            "test" => %{"type" => "string"},
            "command" => %{"type" => "string"},
            "attempted_runs" => %{"type" => "integer"},
            "observed_failures" => %{"type" => "integer"},
            "failure_signature" => %{"type" => "string"},
            "suspected_mechanism" => %{"type" => "string"},
            "evidence" => %{"type" => "string"},
            "confidence" => %{
              "type" => "string",
              "enum" => ["low", "medium", "high"]
            },
            "next_experiment" => %{"type" => "string"}
          },
          "required" => [
            "id",
            "test",
            "command",
            "attempted_runs",
            "observed_failures",
            "failure_signature",
            "suspected_mechanism",
            "evidence",
            "confidence",
            "next_experiment"
          ]
        }
      },
      retries: 1
    )

    collect(into: :items)
  end

  return("flaky-test-hunt-finished; inspect the items accumulator for evidence-backed candidates")
end
