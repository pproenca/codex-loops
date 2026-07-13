defmodule Workflow.ReviewerAdapterTest do
  use ExUnit.Case, async: true

  alias Workflow.Refine.Review
  alias Workflow.Refine.ReviewerAdapter
  alias Workflow.Refine.ReviewFinding

  test "normalizes raw adapter output into typed review data" do
    assert {:ok,
            %Review{
              approved: false,
              findings: [
                %ReviewFinding{
                  id: "V1",
                  blocking: true,
                  issue: "Unsafe behavior.",
                  fix: "Reject it."
                }
              ],
              report_snippets: ["cross-check"]
            }} =
             ReviewerAdapter.normalize(:violations_v1, %{
               "pass" => false,
               "violations" => [
                 %{
                   "id" => "V1",
                   "severity" => "critical",
                   "issue" => "Unsafe behavior.",
                   "fix" => "Reject it."
                 }
               ],
               "report_snippet" => "cross-check"
             })
  end

  test "returns tagged errors for missing or malformed raw fields" do
    assert {:error, {:missing_required, "findings"}} =
             ReviewerAdapter.normalize(:findings_v1, %{"approved" => true})

    assert {:error, :review_finding_unexpected_shape} =
             ReviewerAdapter.normalize(:violations_v1, %{
               "pass" => true,
               "violations" => [
                 %{
                   "id" => "V1",
                   "blocking" => false,
                   "severity" => 1,
                   "issue" => "Unsafe behavior.",
                   "fix" => "Reject it."
                 }
               ]
             })
  end

  test "round-trips the legacy canonical journal payload" do
    payload = %{
      "approved" => true,
      "findings" => [
        %{
          "id" => "F1",
          "blocking" => false,
          "issue" => "Minor issue.",
          "fix" => "Polish it."
        }
      ],
      "report_snippets" => ["note"]
    }

    assert payload |> Review.from_payload() |> Review.to_payload() == payload
  end
end
