workflow "reproduction-confidence-pipeline" do
  phase("independent reproduction")

  log(
    "running three sequential read-only replicas of the same two-stage reproduction protocol; replica names are journal labels only"
  )

  # Pipeline items are journal labels only. The strings below are not injected into either
  # stage prompt, and every lane receives byte-identical prompts.
  #
  # A stage also receives no result from the preceding stage. Consequently both stages are
  # self-contained, read-only investigations, and the terminal does not claim aggregation or
  # consensus that the pipeline cannot compute.
  pipeline(
    ["replica-one", "replica-two", "replica-three"],
    [
      agent(
        """
        Independently attempt to reproduce the repository's currently documented or reported defect.
        This prompt is identical in every pipeline lane: you are not given a replica name, lane index,
        or any pipeline item value.

        Treat repository-root `REPRODUCTION.md` as the sole target contract. It must identify exactly one
        defect, the expected and observed behavior, prerequisites, and a safe reproduction command. Do not
        select a target from issue references, recent diffs, failing tests, or the current task when that
        brief is missing or ambiguous; otherwise replicas could investigate different defects. Record the
        exact environment facts you can establish, then run the smallest existing command that tests the
        brief. Repeat enough times to distinguish deterministic failure, intermittent failure, and
        non-reproduction. Do not edit files, update snapshots, install or upgrade dependencies, clear
        shared caches, mutate external services, or change git state.

        If `REPRODUCTION.md` is absent, names multiple defects, or lacks a safe command, do not invent or
        broaden the target: return `target_identified` false and explain the contract defect. If its command
        is unsafe or would mutate shared state, do not run it; record the blocked command and reason instead.
        """,
        label: "reproduce:controlled-read-only-run",
        schema: %{
          "type" => "object",
          "additionalProperties" => false,
          "properties" => %{
            "target_identified" => %{"type" => "boolean"},
            "target" => %{"type" => "string"},
            "command" => %{"type" => "string"},
            "attempts" => %{"type" => "integer"},
            "failures" => %{"type" => "integer"},
            "reproduced" => %{"type" => "boolean"},
            "failure_signature" => %{"type" => "string"},
            "environment" => %{"type" => "array", "items" => %{"type" => "string"}},
            "evidence" => %{"type" => "array", "items" => %{"type" => "string"}},
            "blocked_reason" => %{"type" => "string"}
          },
          "required" => [
            "target_identified",
            "target",
            "command",
            "attempts",
            "failures",
            "reproduced",
            "failure_signature",
            "environment",
            "evidence",
            "blocked_reason"
          ]
        },
        retries: 1
      ),
      agent(
        """
        Conduct an independent, read-only confounder audit of the repository's currently documented or
        reported defect. This stage receives neither the pipeline item nor the previous stage's result;
        it must read repository-root `REPRODUCTION.md` for itself. That file is the sole target contract and
        must identify exactly one defect, its expected and observed behavior, prerequisites, and a safe
        reproduction command. If the brief is absent, ambiguous, or names multiple defects, return
        `target_identified` false rather than selecting a target from other repository evidence.

        Re-run the brief's minimal reproduction when safe, then test alternative explanations: stale
        generated state, order dependence, random seeds, time zones or clocks, locale, filesystem ordering,
        concurrency, network dependence, leaked environment variables, test isolation, and platform
        assumptions. Distinguish direct observations from inferences. Do not edit files, update snapshots,
        install dependencies, mutate services, or change git state.

        Report high confidence only when the defect reproduces under a controlled command and the main
        confounders have evidence against them. If the target is ambiguous or execution is unsafe,
        return a conservative inconclusive assessment rather than manufacturing certainty.
        """,
        label: "reproduce:independent-confounder-audit",
        schema: %{
          "type" => "object",
          "additionalProperties" => false,
          "properties" => %{
            "target_identified" => %{"type" => "boolean"},
            "target" => %{"type" => "string"},
            "reproduced" => %{"type" => "boolean"},
            "confidence" => %{
              "type" => "string",
              "enum" => ["inconclusive", "low", "medium", "high"]
            },
            "supporting_evidence" => %{
              "type" => "array",
              "items" => %{"type" => "string"}
            },
            "confounders_checked" => %{
              "type" => "array",
              "items" => %{
                "type" => "object",
                "additionalProperties" => false,
                "properties" => %{
                  "name" => %{"type" => "string"},
                  "assessment" => %{"type" => "string"},
                  "evidence" => %{"type" => "string"}
                },
                "required" => ["name", "assessment", "evidence"]
              }
            },
            "remaining_uncertainty" => %{
              "type" => "array",
              "items" => %{"type" => "string"}
            }
          },
          "required" => [
            "target_identified",
            "target",
            "reproduced",
            "confidence",
            "supporting_evidence",
            "confounders_checked",
            "remaining_uncertainty"
          ]
        },
        retries: 1
      )
    ],
    # Replicas share one workspace. Serial admission prevents concurrent commands from contending
    # on ports, caches, databases, or temporary paths and manufacturing a false reproduction.
    max_concurrency: 1
  )

  return(
    "reproduction replicas finished; inspect pipeline lane events individually because no result aggregation occurred"
  )
end
