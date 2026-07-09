defmodule CodexLoopsConformanceCore do
  use Workflow

  workflow "conformance-core" do
    phase("core")
    log("exercise every adopted orchestration family")

    let(
      :receipt =
        agent("Return a receipt.",
          schema: %{
            "type" => "object",
            "properties" => %{"receipt" => %{"type" => "string"}},
            "required" => ["receipt"]
          }
        )
    )

    parallel([agent("parallel-a"), agent("parallel-b")], max_concurrency: 2)
    pipeline(["one", "two"], [agent("pipeline-read"), agent("pipeline-write")])

    verify("voter panel", voters: 3, threshold: :majority)
    verify("lens panel", lenses: [:correctness, :safety], threshold: :unanimous)
    judge(["a", "b"], by: [:impact, :effort], pick: :max_score)
    judge(["a", "b"], by: [:risk], pick: :min_score)
    synthesize(["a", "b"], "Synthesize the inputs.")

    loop max_iterations: 1, until: path_exists(:receipt, "/receipt") do
      agent("header predicate should skip this turn")
    end

    loop max_iterations: 2 do
      fanout width: 1, bind: :checks do
        agent("Return approval.",
          schema: %{
            "type" => "object",
            "properties" => %{"approved" => %{"type" => "boolean"}},
            "required" => ["approved"]
          }
        )
      end

      until(agree(:checks, path: "/approved", equals: true, threshold: :all))
      agent("body predicate should skip this turn")
    end

    while_budget reserve: 0, max_iterations: 1 do
      agent("legacy budget loop")
    end

    until_dry rounds: 1, seen_by: [:id], max_iterations: 2 do
      agent("Return no new items.",
        schema: %{
          "type" => "array",
          "items" => %{
            "type" => "object",
            "properties" => %{"id" => %{"type" => "string"}},
            "required" => ["id"]
          }
        }
      )

      collect(into: :items)
    end

    fanout width: 2 do
      agent("repeated-lane-a")
      agent("repeated-lane-b")
    end

    fanout width: 2 do
      lanes([
        [agent("explicit-research")],
        [agent("explicit-draft"), agent("explicit-review")]
      ])
    end

    fanout width: budget_slices(per: 9_000, max: 1) do
      agent("core budget fanout")
    end

    fan_out width: budget_slices(per: 9_000) do
      agent("legacy budget fanout")
    end

    return(:ok)
  end
end
