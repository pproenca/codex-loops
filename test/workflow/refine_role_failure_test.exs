defmodule Workflow.Refine.RoleFailureTest do
  use ExUnit.Case, async: true

  alias Workflow.Refine.RoleFailure

  test "owns the complete role failure reason variant set" do
    detail = %{"message" => "failed"}

    assert RoleFailure.reason_code({:provider_failure, :timeout, detail}) == "provider_failure"
    assert RoleFailure.reason_code({:malformed_output, :invalid}) == "malformed_output"
    assert RoleFailure.reason_code({:reviewer_timeout, 100}) == "reviewer_timeout"
    assert RoleFailure.reason_code({:cold_read_timeout, 200}) == "cold_read_timeout"
    assert RoleFailure.reason_code({:reviewer_crashed, :killed}) == "reviewer_crashed"
    assert RoleFailure.reason_code({:cold_read_crashed, :killed}) == "cold_read_crashed"
    assert RoleFailure.reason_code({:repair_failed, :invalid}) == "repair_failed"
  end

  test "builds reason maps with projection-owned detail encoding" do
    encode_provider = fn detail -> {:public, detail} end
    encode_diagnostic = fn detail -> {:diagnostic, detail} end

    assert RoleFailure.reason_map(
             {:provider_failure, :timeout, %{"message" => "failed"}},
             provider_detail: encode_provider,
             diagnostic_detail: encode_diagnostic
           ) == %{
             "code" => "provider_failure",
             "kind" => "timeout",
             "detail" => {:public, %{"message" => "failed"}}
           }

    assert RoleFailure.reason_map({:reviewer_timeout, 100},
             provider_detail: encode_provider,
             diagnostic_detail: encode_diagnostic
           ) == %{"code" => "reviewer_timeout", "timeoutMs" => 100}

    assert RoleFailure.reason_map({:repair_failed, :invalid},
             provider_detail: encode_provider,
             diagnostic_detail: encode_diagnostic
           ) == %{"code" => "repair_failed", "detail" => {:diagnostic, :invalid}}
  end

  test "keeps legacy atom and unknown reasons stable" do
    encoders = [provider_detail: &Function.identity/1, diagnostic_detail: &inspect/1]

    assert RoleFailure.reason_map(:cancelled, encoders) == %{"code" => "cancelled"}

    assert RoleFailure.reason_map({:future, 1, 2, 3}, encoders) == %{
             "code" => "unknown",
             "detail" => "{:future, 1, 2, 3}"
           }
  end
end
