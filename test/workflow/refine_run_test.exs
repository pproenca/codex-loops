defmodule Workflow.RefineRunTest do
  use ExUnit.Case, async: false

  alias Workflow.Journal
  alias Workflow.Ledger
  alias Workflow.Provider.Usage
  alias Workflow.Run
  alias Workflow.Status
  alias Workflow.Test.ExplodingProvider
  alias Workflow.Test.RefineProvider
  alias Workflow.Test.ScriptedProvider

  @moduletag :capture_log

  defmodule ReplayStartedProvider do
    @moduledoc false
    @behaviour Workflow.Provider

    @impl true
    def run_agent(prompt, _schema, key, opts) do
      sink = Keyword.fetch!(opts, :sink)
      send(sink, {:agent_called, prompt, key})

      output =
        case key.node_path do
          [0, 0] ->
            if key.attempt == 0 do
              %{"artifact" => 123}
            else
              %{"artifact" => "draft-v1"}
            end

          [0, 1, reviewer_index] ->
            send(sink, {:reviewer_entered, prompt, key, self()})

            receive do
              :release_reviewer -> :ok
            after
              5_000 -> raise "reviewer #{inspect(key.node_path)} was not released"
            end

            review_for(key.iteration, reviewer_index)

          [0, 2] ->
            if key.attempt == 0 do
              %{"artifact" => 123}
            else
              %{"artifact" => "draft-v2"}
            end
        end

      {:ok, output, %Usage{input_tokens: 1, output_tokens: 1, total_tokens: 2}}
    end

    defp review_for(0, 0) do
      %{
        "approved" => false,
        "findings" => [
          %{
            "id" => "spec-gap",
            "blocking" => true,
            "issue" => "Spec is ambiguous.",
            "fix" => "Pin the behavior."
          }
        ]
      }
    end

    defp review_for(_iteration, _reviewer_index), do: %{"approved" => true, "findings" => []}
  end

  defmodule ProducerRetryCrashProvider do
    @moduledoc false
    @behaviour Workflow.Provider

    @impl true
    def run_agent(prompt, _schema, key, opts) do
      sink = Keyword.fetch!(opts, :sink)
      send(sink, {:agent_called, prompt, key})

      output =
        case key.node_path do
          [0, 0] when key.attempt == 0 ->
            %{"artifact" => 123}

          [0, 0] ->
            raise "producer crashed after a rejected attempt"
        end

      {:ok, output, %Usage{input_tokens: 1, output_tokens: 1, total_tokens: 2}}
    end
  end

  defmodule ReviserRetryCrashProvider do
    @moduledoc false
    @behaviour Workflow.Provider

    @impl true
    def run_agent(prompt, _schema, key, opts) do
      sink = Keyword.fetch!(opts, :sink)
      send(sink, {:agent_called, prompt, key})

      output =
        case key.node_path do
          [0, 0] ->
            %{"artifact" => "draft-v1"}

          [0, 1, 0] ->
            %{
              "approved" => false,
              "findings" => [
                %{
                  "id" => "spec-gap",
                  "blocking" => true,
                  "issue" => "Spec is ambiguous.",
                  "fix" => "Pin the behavior."
                }
              ]
            }

          [0, 1, 1] ->
            %{"approved" => true, "findings" => []}

          [0, 2] when key.attempt == 0 ->
            %{"artifact" => 123}

          [0, 2] ->
            raise "reviser crashed after a rejected attempt"
        end

      {:ok, output, %Usage{input_tokens: 1, output_tokens: 1, total_tokens: 2}}
    end
  end

  defmodule SlowReviewerProvider do
    @moduledoc false
    @behaviour Workflow.Provider

    @impl true
    def run_agent(prompt, _schema, key, opts) do
      if sink = Keyword.get(opts, :sink), do: send(sink, {:agent_called, prompt, key})

      output =
        case key.node_path do
          [0, 0] ->
            %{"artifact" => "draft-v1"}

          [0, 1, 0] when key.iteration == 0 ->
            Process.sleep(100)
            %{"approved" => true, "findings" => []}

          [0, 1, _reviewer_index] ->
            %{"approved" => true, "findings" => []}

          [0, 2] ->
            %{"artifact" => "draft-v2"}
        end

      {:ok, output, %Usage{input_tokens: 1, output_tokens: 1, total_tokens: 2}}
    end
  end

  defmodule KilledReviewerProvider do
    @moduledoc false
    @behaviour Workflow.Provider

    @impl true
    def run_agent(prompt, _schema, key, opts) do
      if sink = Keyword.get(opts, :sink), do: send(sink, {:agent_called, prompt, key})

      output =
        case key.node_path do
          [0, 0] ->
            %{"artifact" => "draft-v1"}

          [0, 1, 0] when key.iteration == 0 ->
            Process.exit(self(), :kill)

          [0, 1, _reviewer_index] ->
            %{"approved" => true, "findings" => []}

          [0, 2] ->
            %{"artifact" => "draft-v2"}
        end

      {:ok, output, %Usage{input_tokens: 1, output_tokens: 1, total_tokens: 2}}
    end
  end

  defmodule ColdReadLaneFailureProvider do
    @moduledoc false
    @behaviour Workflow.Provider

    @impl true
    def run_agent(prompt, _schema, key, opts) do
      if sink = Keyword.get(opts, :sink), do: send(sink, {:agent_called, prompt, key})

      output =
        case key.node_path do
          [0, 0] ->
            %{"artifact" => "draft-v1"}

          [0, 1, 0] ->
            %{
              "approved" => false,
              "findings" => [
                %{
                  "id" => "base-gap",
                  "blocking" => true,
                  "issue" => "Base review found a gap.",
                  "fix" => "Repair the base gap."
                }
              ]
            }

          [0, 1, 1] ->
            %{"approved" => true, "findings" => []}

          [0, 3] ->
            case Keyword.fetch!(opts, :failure) do
              :timeout ->
                Process.sleep(100)
                %{"approved" => true, "findings" => []}

              :killed ->
                Process.exit(self(), :kill)
            end
        end

      {:ok, output, %Usage{input_tokens: 1, output_tokens: 1, total_tokens: 2}}
    end
  end

  defmodule ReviewerRoleFailureProvider do
    @moduledoc false
    @behaviour Workflow.Provider

    @impl true
    def run_agent(prompt, _schema, key, opts) do
      if sink = Keyword.get(opts, :sink), do: send(sink, {:agent_called, prompt, key})

      case key.node_path do
        [0, 0] ->
          {:ok, %{"artifact" => "draft-v1"}, usage(2)}

        [0, 1, 0] when key.iteration == 0 ->
          reviewer_failure(Keyword.fetch!(opts, :failure))

        [0, 1, _reviewer_index] ->
          {:ok, %{"approved" => true, "findings" => []}, usage(2)}

        [0, 2] ->
          {:ok, %{"artifact" => "draft-v2"}, usage(2)}
      end
    end

    defp reviewer_failure(:schema) do
      {:ok, %{"approved" => true}, usage(2)}
    end

    defp reviewer_failure(:provider_failure) do
      detail = %{"message" => "provider timeout", "retryable" => true}

      activity = [
        %{
          kind: "provider",
          label: "Provider",
          summary: "reviewer timed out",
          status: "failed"
        }
      ]

      {:error, {:provider_failure, :timeout, detail, usage(7), activity}}
    end

    defp usage(total), do: %Usage{input_tokens: total, output_tokens: 0, total_tokens: total}
  end

  defmodule InlineConverges do
    @moduledoc false
    use Workflow

    workflow "inline-converges" do
      refine(agent("Draft."),
        reviewers: [
          reviewer(:spec, "Check the spec."),
          reviewer(:runtime, "Check the runtime.")
        ],
        revise_with: agent("Fix."),
        until: :unanimous,
        max_rounds: 3
      )

      return(:ok)
    end
  end

  defmodule ChangedInlineConverges do
    @moduledoc false
    use Workflow

    workflow "changed-inline-converges" do
      refine(agent("Changed draft."),
        reviewers: [
          reviewer(:changed_spec, "Changed spec."),
          reviewer(:changed_runtime, "Changed runtime."),
          reviewer(:changed_extra, "Changed extra.")
        ],
        revise_with: agent("Changed fix."),
        until: :unanimous,
        max_rounds: 3,
        max_concurrency: 3
      )

      return(:ok)
    end
  end

  defmodule BoundConverges do
    @moduledoc false
    use Workflow

    workflow "bound-converges" do
      let(:draft = agent("Draft."))

      refine(:draft,
        reviewers: [
          reviewer(:spec, "Check the spec."),
          reviewer(:runtime, "Check the runtime.")
        ],
        revise_with: agent("Fix."),
        until: :unanimous,
        max_rounds: 3
      )

      return(:ok)
    end
  end

  defmodule BoundInvalidObject do
    @moduledoc false
    use Workflow

    workflow "bound-invalid-object" do
      let(:draft = agent("Draft.", schema: %{"type" => "object", "required" => ["not_artifact"]}))

      refine(:draft,
        reviewers: [
          reviewer(:spec, "Check the spec."),
          reviewer(:runtime, "Check the runtime.")
        ],
        revise_with: agent("Fix."),
        until: :unanimous,
        max_rounds: 3
      )

      return(:ok)
    end
  end

  defmodule BoundArtifactObjectConverges do
    @moduledoc false
    use Workflow

    workflow "bound-artifact-object-converges" do
      let(:draft = agent("Draft.", schema: %{"type" => "object", "required" => ["artifact"]}))

      refine(:draft,
        reviewers: [
          reviewer(:spec, "Check the spec."),
          reviewer(:runtime, "Check the runtime.")
        ],
        revise_with: agent("Fix."),
        until: :unanimous,
        max_rounds: 3
      )

      return(:ok)
    end
  end

  defmodule NonConvergesFail do
    @moduledoc false
    use Workflow

    workflow "non-converges-fail" do
      refine(agent("Draft."),
        reviewers: [
          reviewer(:spec, "Check the spec."),
          reviewer(:runtime, "Check the runtime.")
        ],
        revise_with: agent("Fix."),
        until: :unanimous,
        max_rounds: 1
      )

      return(:ok)
    end
  end

  defmodule NonConvergesAccept do
    @moduledoc false
    use Workflow

    workflow "non-converges-accept" do
      refine(agent("Draft."),
        reviewers: [
          reviewer(:spec, "Check the spec."),
          reviewer(:runtime, "Check the runtime.")
        ],
        revise_with: agent("Fix."),
        until: :unanimous,
        max_rounds: 1,
        on_non_convergence: :accept_current
      )

      return(:ok)
    end
  end

  defmodule AdapterConverges do
    @moduledoc false
    use Workflow

    workflow "adapter-converges" do
      refine(agent("Draft."),
        reviewers: [
          reviewer(:findings, "Find findings."),
          reviewer(:defects, "Find defects.", adapter: :defects_v1),
          reviewer(:violations, "Find violations.", adapter: :violations_v1),
          reviewer(:concerns, "Find concerns.", adapter: :concerns_v1)
        ],
        revise_with: agent("Fix."),
        until: :unanimous,
        max_rounds: 1,
        max_concurrency: 1
      )

      return(:ok)
    end
  end

  defmodule AcceptCurrentEmit do
    @moduledoc false
    use Workflow

    workflow "accept-current-emit" do
      let(
        :final =
          refine(agent("Draft."),
            reviewers: [
              reviewer(:spec, "Check the spec."),
              reviewer(:runtime, "Check the runtime.")
            ],
            revise_with: agent("Fix."),
            until: :unanimous,
            max_rounds: 1,
            on_non_convergence: :accept_current
          )
      )

      emit(~P"Final: <%= @final %>")
    end
  end

  defmodule GateColdRepairEmitResult do
    @moduledoc false
    use Workflow

    workflow "gate-cold-repair-emit-result" do
      let(
        :final =
          refine(agent("Draft."),
            reviewers: [
              reviewer(:spec, "Check the spec."),
              reviewer(:runtime, "Check the runtime.")
            ],
            revise_with: agent("Repair."),
            until: :unanimous,
            max_rounds: 1,
            on_non_convergence: :accept_current,
            gates: [
              cold_read: [
                reviewer: reviewer(:cold, "Cold read."),
                when: path_non_empty("/openFindings")
              ],
              repair_when: path_non_empty("/coldRead/openFindings")
            ]
          )
      )

      emit_result(:final)
    end
  end

  defmodule GateHaltAcceptCurrent do
    @moduledoc false
    use Workflow

    workflow "gate-halt-accept-current" do
      refine(agent("Draft."),
        reviewers: [
          reviewer(:spec, "Check the spec."),
          reviewer(:runtime, "Check the runtime.")
        ],
        revise_with: agent("Repair."),
        until: :unanimous,
        max_rounds: 1,
        on_non_convergence: :accept_current,
        gates: [
          halt_when: path_non_empty("/openFindings")
        ]
      )

      return(:ok)
    end
  end

  defmodule GateRepairReplayExhausted do
    @moduledoc false
    use Workflow

    workflow "gate-repair-replay-exhausted" do
      refine(agent("Draft."),
        reviewers: [
          reviewer(:spec, "Check the spec."),
          reviewer(:runtime, "Check the runtime.")
        ],
        revise_with: agent("Repair."),
        until: :unanimous,
        max_rounds: 1,
        on_non_convergence: :accept_current,
        gates: [
          repair_when: path_non_empty("/openFindings")
        ]
      )

      return(:ok)
    end
  end

  defmodule GateReplayColdTrue do
    @moduledoc false
    use Workflow

    workflow "gate-replay-cold-true" do
      refine(agent("Draft."),
        reviewers: [
          reviewer(:spec, "Check the spec."),
          reviewer(:runtime, "Check the runtime.")
        ],
        revise_with: agent("Repair."),
        until: :unanimous,
        max_rounds: 1,
        on_non_convergence: :accept_current,
        gates: [
          cold_read: [
            reviewer: reviewer(:cold, "Journaled cold read."),
            when: path_non_empty("/openFindings")
          ]
        ]
      )

      return(:ok)
    end
  end

  defmodule GateReplayColdFalseEdit do
    @moduledoc false
    use Workflow

    workflow "gate-replay-cold-false-edit" do
      refine(agent("Changed draft."),
        reviewers: [
          reviewer(:changed_spec, "Changed spec."),
          reviewer(:changed_runtime, "Changed runtime.")
        ],
        revise_with: agent("Changed repair."),
        until: :unanimous,
        max_rounds: 1,
        on_non_convergence: :accept_current,
        gates: [
          cold_read: [
            reviewer: reviewer(:changed_cold, "Changed cold read."),
            when: path_non_empty("/definitelyMissing")
          ]
        ]
      )

      return(:ok)
    end
  end

  defp run_id, do: "run_#{System.unique_integer([:positive])}"
  defp events(id), do: Journal.fold(id)
  defp types(id), do: id |> events() |> Enum.map(& &1.type)

  defp await_lease_released(run_id, tries \\ 200) do
    cond do
      Registry.lookup(Workflow.Run.Registry, run_id) == [] ->
        :ok

      tries == 0 ->
        flunk("lease for #{run_id} was never released")

      true ->
        Process.sleep(5)
        await_lease_released(run_id, tries - 1)
    end
  end

  defp flush_agent_calls do
    receive do
      {:agent_called, _, _} -> flush_agent_calls()
      {:agent_called, _} -> flush_agent_calls()
    after
      0 -> :ok
    end
  end

  defp stable_refine_started_event(node) do
    event = Workflow.Event.refine_started(node)

    reviewers =
      Enum.map(event.payload.reviewers, fn reviewer ->
        %{reviewer | label: "stable-#{reviewer.name}"}
      end)

    %{
      event
      | payload: %{
          event.payload
          | input: %{event.payload.input | retries: 1, label: "stable-producer"},
            reviewers: reviewers,
            reviser: %{event.payload.reviser | retries: 1, label: "stable-reviser"},
            max_concurrency: 1
        }
    }
  end

  defp append_events(id, journal_events) do
    _next_seq =
      Enum.reduce(journal_events, 0, fn event, seq ->
        assert :ok = Journal.append(id, seq, event)
        seq + 1
      end)

    :ok
  end

  defp key(run_id, address, iteration, attempt \\ 0) do
    %Workflow.IdempotencyKey{
      run_id: run_id,
      node_path: address,
      iteration: iteration,
      attempt: attempt
    }
  end

  defp assert_next_reviewer(address, iteration) do
    assert_receive {:reviewer_entered, prompt, key, pid}
    assert key.node_path == address
    assert key.iteration == iteration
    refute_receive {:reviewer_entered, _, _, _}, 50
    send(pid, :release_reviewer)
    prompt
  end

  test "inline producer converges in round 0 without invoking the reviser" do
    id = run_id()

    assert {:ok, ^id} =
             Run.run(InlineConverges,
               run_id: id,
               provider:
                 {RefineProvider,
                  artifact: "draft-v1",
                  reviews: [
                    [approved: true, findings: []],
                    [approved: true, findings: []]
                  ],
                  sink: self()}
             )

    assert_received {:agent_called, "Draft.", %{node_path: [0, 0], iteration: 0}}
    assert_received {:agent_called, spec_prompt, %{node_path: [0, 1, 0], iteration: 0}}
    assert_received {:agent_called, runtime_prompt, %{node_path: [0, 1, 1], iteration: 0}}
    refute_received {:agent_called, "Fix.", _}

    assert spec_prompt =~ "Check the spec."
    assert spec_prompt =~ "artifact:\ndraft-v1"
    assert runtime_prompt =~ "Check the runtime."
    assert runtime_prompt =~ "artifact:\ndraft-v1"

    assert types(id) ==
             [
               :run_started,
               :refine_started,
               :agent_committed,
               :refine_round_started,
               :agent_committed,
               :agent_committed,
               :refine_round_decision,
               :refine_completed,
               :run_completed
             ]

    started = Enum.find(events(id), &(&1.type == :refine_started)).payload

    assert started.review_schema_version == 1

    assert started.review_adapter_versions == %{
             findings_v1: 1,
             defects_v1: 1,
             violations_v1: 1,
             concerns_v1: 1
           }

    committed =
      id
      |> events()
      |> Enum.filter(&(&1.type == :agent_committed))

    assert [
             %{payload: %{address: [0, 0], iteration: 0, result: "draft-v1"}},
             %{
               payload: %{
                 address: [0, 1, 0],
                 iteration: 0,
                 result: %{"approved" => true, "findings" => []}
               }
             },
             %{
               payload: %{
                 address: [0, 1, 1],
                 iteration: 0,
                 result: %{"approved" => true, "findings" => []}
               }
             }
           ] = committed

    decision = Enum.find(events(id), &(&1.type == :refine_round_decision)).payload

    assert decision == %{
             address: [0],
             round: 0,
             consensus: true,
             approval_count: 2,
             total: 2,
             artifact: "draft-v1",
             open_findings: [],
             reviewer_decisions: [
               %{
                 reviewer: :spec,
                 reviewer_index: 0,
                 approved: true,
                 clear: true,
                 adapter: :findings_v1,
                 status: :completed
               },
               %{
                 reviewer: :runtime,
                 reviewer_index: 1,
                 approved: true,
                 clear: true,
                 adapter: :findings_v1,
                 status: :completed
               }
             ],
             role_failures: [],
             failed_reviewers: [],
             report_snippets: []
           }

    completed = Enum.find(events(id), &(&1.type == :refine_completed)).payload
    assert completed.artifact == "draft-v1"
    assert completed.converged == true
    assert completed.open_findings == []

    status = Status.of(id)
    assert status.state == :completed
    assert status.result == :ok
  end

  test "reviewer adapters normalize canonical results and report snippets" do
    id = run_id()

    {:ok, script} =
      ScriptedProvider.start([
        %{"artifact" => "draft-v1"},
        %{
          "approved" => true,
          "findings" => [],
          "cross_expert_note" => "findings note",
          "report_snippet" => "findings snippet"
        },
        %{
          "pass" => true,
          "defects" => [
            %{
              "id" => "D1",
              "blocking" => false,
              "issue" => "Cosmetic defect.",
              "fix" => "Polish it."
            }
          ],
          "cross_expert_note" => "defects note",
          "report_snippet" => "defects snippet"
        },
        %{
          "pass" => true,
          "violations" => [
            %{
              "id" => "V1",
              "severity" => "warning",
              "issue" => "Style violation.",
              "fix" => "Format it."
            }
          ],
          "report_snippet" => "violations snippet"
        },
        %{
          "verdict" => "approve",
          "concerns" => [],
          "cross_expert_note" => "concerns note"
        }
      ])

    assert {:ok, ^id} =
             Run.run(AdapterConverges,
               run_id: id,
               provider: {ScriptedProvider, script: script, sink: self()}
             )

    started = Enum.find(events(id), &(&1.type == :refine_started)).payload

    assert Enum.map(started.reviewers, &{&1.name, &1.adapter}) == [
             {:findings, :findings_v1},
             {:defects, :defects_v1},
             {:violations, :violations_v1},
             {:concerns, :concerns_v1}
           ]

    committed_reviews =
      id
      |> events()
      |> Enum.filter(&(&1.type == :agent_committed and List.starts_with?(&1.payload.address, [0, 1])))
      |> Enum.map(& &1.payload.result)

    assert committed_reviews == [
             %{
               "approved" => true,
               "findings" => [],
               "report_snippets" => ["findings note", "findings snippet"]
             },
             %{
               "approved" => true,
               "findings" => [
                 %{
                   "id" => "D1",
                   "blocking" => false,
                   "issue" => "Cosmetic defect.",
                   "fix" => "Polish it."
                 }
               ],
               "report_snippets" => ["defects note", "defects snippet"]
             },
             %{
               "approved" => true,
               "findings" => [
                 %{
                   "id" => "V1",
                   "blocking" => false,
                   "issue" => "Style violation.",
                   "fix" => "Format it."
                 }
               ],
               "report_snippets" => ["violations snippet"]
             },
             %{"approved" => true, "findings" => [], "report_snippets" => ["concerns note"]}
           ]

    decision = Enum.find(events(id), &(&1.type == :refine_round_decision)).payload

    assert Enum.map(decision.reviewer_decisions, &{&1.reviewer, &1.adapter, &1.status, &1.clear}) ==
             [
               {:findings, :findings_v1, :completed, true},
               {:defects, :defects_v1, :completed, true},
               {:violations, :violations_v1, :completed, true},
               {:concerns, :concerns_v1, :completed, true}
             ]

    assert decision.report_snippets == [
             "findings note",
             "findings snippet",
             "defects note",
             "defects snippet",
             "violations snippet",
             "concerns note"
           ]

    assert decision.open_findings == []
  end

  test "blocking findings drive one reviser round before reviewers converge" do
    id = run_id()

    assert {:ok, ^id} =
             Run.run(InlineConverges,
               run_id: id,
               provider:
                 {RefineProvider,
                  artifact: "draft-v1",
                  revised_artifacts: ["draft-v2"],
                  review_rounds: [
                    [
                      [
                        approved: false,
                        findings: [
                          %{
                            "id" => "spec-gap",
                            "blocking" => true,
                            "issue" => "Spec is ambiguous.",
                            "fix" => "Pin the behavior."
                          }
                        ]
                      ],
                      [approved: true, findings: []]
                    ],
                    [
                      [approved: true, findings: []],
                      [approved: true, findings: []]
                    ]
                  ],
                  sink: self()}
             )

    assert_received {:agent_called, "Draft.", %{node_path: [0, 0], iteration: 0}}
    assert_received {:agent_called, _round0_spec_prompt, %{node_path: [0, 1, 0], iteration: 0}}
    assert_received {:agent_called, _round0_runtime_prompt, %{node_path: [0, 1, 1], iteration: 0}}
    assert_received {:agent_called, reviser_prompt, %{node_path: [0, 2], iteration: 0}}
    assert_received {:agent_called, round1_spec_prompt, %{node_path: [0, 1, 0], iteration: 1}}
    assert_received {:agent_called, round1_runtime_prompt, %{node_path: [0, 1, 1], iteration: 1}}
    refute_received {:agent_called, _, _}

    assert reviser_prompt =~ "Fix."
    assert reviser_prompt =~ "--- CODEX LOOPS REFINE REVISION INPUT ---"
    assert reviser_prompt =~ "round: 0"
    assert reviser_prompt =~ "current-artifact:\ndraft-v1"
    assert reviser_prompt =~ "blocking-finding-count: 1"
    assert reviser_prompt =~ "reviewer: spec"
    assert reviser_prompt =~ "id:\nspec-gap"
    assert reviser_prompt =~ "issue:\nSpec is ambiguous."
    assert reviser_prompt =~ "fix:\nPin the behavior."
    assert round1_spec_prompt =~ "artifact:\ndraft-v2"
    assert round1_runtime_prompt =~ "artifact:\ndraft-v2"

    assert types(id) ==
             [
               :run_started,
               :refine_started,
               :agent_committed,
               :refine_round_started,
               :agent_committed,
               :agent_committed,
               :refine_round_decision,
               :agent_committed,
               :refine_round_started,
               :agent_committed,
               :agent_committed,
               :refine_round_decision,
               :refine_completed,
               :run_completed
             ]

    decisions =
      id
      |> events()
      |> Enum.filter(&(&1.type == :refine_round_decision))
      |> Enum.map(& &1.payload)

    assert [
             %{
               round: 0,
               consensus: false,
               approval_count: 1,
               total: 2,
               artifact: "draft-v1",
               open_findings: [
                 %{
                   reviewer: :spec,
                   reviewer_index: 0,
                   id: "spec-gap",
                   issue: "Spec is ambiguous.",
                   fix: "Pin the behavior."
                 }
               ]
             },
             %{
               round: 1,
               consensus: true,
               approval_count: 2,
               total: 2,
               artifact: "draft-v2",
               open_findings: []
             }
           ] = decisions

    completed = Enum.find(events(id), &(&1.type == :refine_completed)).payload
    assert completed.final_round == 1
    assert completed.rounds == 2
    assert completed.artifact == "draft-v2"
    assert completed.converged == true
  end

  test "open findings dedupe duplicate blocking ids per reviewer with first occurrence winning" do
    id = run_id()

    assert {:ok, ^id} =
             Run.run(NonConvergesAccept,
               run_id: id,
               provider:
                 {RefineProvider,
                  artifact: "draft-v1",
                  reviews: [
                    [
                      approved: false,
                      findings: [
                        %{
                          "id" => "z-repeat",
                          "blocking" => true,
                          "issue" => "first repeat issue",
                          "fix" => "first repeat fix"
                        },
                        %{
                          "id" => "a-first",
                          "blocking" => true,
                          "issue" => "first sorted issue",
                          "fix" => "first sorted fix"
                        },
                        %{
                          "id" => "z-repeat",
                          "blocking" => true,
                          "issue" => "second repeat issue",
                          "fix" => "second repeat fix"
                        }
                      ]
                    ],
                    [approved: true, findings: []]
                  ],
                  sink: self()}
             )

    decision = Enum.find(events(id), &(&1.type == :refine_round_decision)).payload

    assert decision.open_findings == [
             %{
               reviewer: :spec,
               reviewer_index: 0,
               id: "a-first",
               issue: "first sorted issue",
               fix: "first sorted fix"
             },
             %{
               reviewer: :spec,
               reviewer_index: 0,
               id: "z-repeat",
               issue: "first repeat issue",
               fix: "first repeat fix"
             }
           ]
  end

  test "resume after committed reviser reviews the revised artifact without rerunning prior roles" do
    id = run_id()
    node = hd(InlineConverges.__workflow__(:tree).nodes)

    key = fn address, iteration ->
      %Workflow.IdempotencyKey{run_id: id, node_path: address, iteration: iteration, attempt: 0}
    end

    prior_events = [
      Workflow.Event.run_started(InlineConverges.__workflow__(:tree)),
      Workflow.Event.refine_started(node),
      Workflow.Event.agent_committed(
        %Workflow.Node.Agent{address: [0, 0], prompt: "Draft."},
        0,
        key.([0, 0], 0),
        "draft-v1",
        %Usage{}
      ),
      Workflow.Event.refine_round_started(node, 0, "draft-v1"),
      Workflow.Event.agent_committed(
        %Workflow.Node.Agent{address: [0, 1, 0], prompt: "Check the spec."},
        0,
        key.([0, 1, 0], 0),
        %{
          "approved" => false,
          "findings" => [
            %{
              "id" => "spec-gap",
              "blocking" => true,
              "issue" => "Spec is ambiguous.",
              "fix" => "Pin the behavior."
            }
          ]
        },
        %Usage{}
      ),
      Workflow.Event.agent_committed(
        %Workflow.Node.Agent{address: [0, 1, 1], prompt: "Check the runtime."},
        0,
        key.([0, 1, 1], 0),
        %{"approved" => true, "findings" => []},
        %Usage{}
      ),
      Workflow.Event.refine_round_decision(node, 0, %{
        consensus: false,
        approval_count: 1,
        total: 2,
        reviewer_decisions: [
          %{reviewer: :spec, reviewer_index: 0, approved: false, clear: false},
          %{reviewer: :runtime, reviewer_index: 1, approved: true, clear: true}
        ],
        artifact: "draft-v1",
        open_findings: [
          %{
            reviewer: :spec,
            reviewer_index: 0,
            id: "spec-gap",
            issue: "Spec is ambiguous.",
            fix: "Pin the behavior."
          }
        ]
      }),
      Workflow.Event.agent_committed(
        %Workflow.Node.Agent{address: [0, 2], prompt: "Fix."},
        0,
        key.([0, 2], 0),
        "draft-v2",
        %Usage{}
      )
    ]

    Enum.reduce(prior_events, 0, fn event, seq ->
      assert :ok = Journal.append(id, seq, event)
      seq + 1
    end)

    assert {:ok, ^id} =
             Run.run(InlineConverges,
               run_id: id,
               provider:
                 {RefineProvider,
                  artifact: "unused",
                  review_rounds: [
                    [
                      [approved: false, findings: []],
                      [approved: true, findings: []]
                    ],
                    [
                      [approved: true, findings: []],
                      [approved: true, findings: []]
                    ]
                  ],
                  revised_artifacts: ["SHOULD NOT REVISE"],
                  sink: self()}
             )

    assert_received {:agent_called, round1_spec_prompt, %{node_path: [0, 1, 0], iteration: 1}}

    assert_received {:agent_called, round1_runtime_prompt, %{node_path: [0, 1, 1], iteration: 1}}

    refute_received {:agent_called, _, _}

    assert round1_spec_prompt =~ "artifact:\ndraft-v2"
    assert round1_runtime_prompt =~ "artifact:\ndraft-v2"

    committed_addresses =
      id
      |> events()
      |> Enum.filter(&(&1.type == :agent_committed))
      |> Enum.map(& &1.payload.address)

    assert Enum.count(committed_addresses, &(&1 == [0, 0])) == 1
    assert Enum.count(committed_addresses, &(&1 == [0, 2])) == 1
    assert Enum.count(types(id), &(&1 == :refine_round_started)) == 2
    assert Enum.count(types(id), &(&1 == :refine_round_decision)) == 2

    completed = Enum.find(events(id), &(&1.type == :refine_completed)).payload
    assert completed.final_round == 1
    assert completed.artifact == "draft-v2"
    assert completed.converged == true
  end

  test "resume replays refine_started descriptors instead of changed compiled source" do
    id = run_id()
    node = hd(InlineConverges.__workflow__(:tree).nodes)

    prior_events = [
      Workflow.Event.run_started(InlineConverges.__workflow__(:tree)),
      stable_refine_started_event(node)
    ]

    Enum.reduce(prior_events, 0, fn event, seq ->
      assert :ok = Journal.append(id, seq, event)
      seq + 1
    end)

    assert {:ok, ^id, _pid} =
             Run.start(ChangedInlineConverges,
               run_id: id,
               provider: {ReplayStartedProvider, sink: self()}
             )

    assert_receive {:agent_called, "Draft.", %{node_path: [0, 0], attempt: 0}}
    assert_receive {:agent_called, "Draft.", %{node_path: [0, 0], attempt: 1}}

    round0_spec_prompt = assert_next_reviewer([0, 1, 0], 0)
    assert round0_spec_prompt =~ "Check the spec."
    assert round0_spec_prompt =~ "artifact:\ndraft-v1"

    round0_runtime_prompt = assert_next_reviewer([0, 1, 1], 0)
    assert round0_runtime_prompt =~ "Check the runtime."
    assert round0_runtime_prompt =~ "artifact:\ndraft-v1"

    assert_receive {:agent_called, reviser_prompt, %{node_path: [0, 2], attempt: 0}}
    assert_receive {:agent_called, ^reviser_prompt, %{node_path: [0, 2], attempt: 1}}
    assert reviser_prompt =~ "Fix."
    assert reviser_prompt =~ "current-artifact:\ndraft-v1"
    assert reviser_prompt =~ "id:\nspec-gap"

    round1_spec_prompt = assert_next_reviewer([0, 1, 0], 1)
    assert round1_spec_prompt =~ "Check the spec."
    assert round1_spec_prompt =~ "artifact:\ndraft-v2"

    round1_runtime_prompt = assert_next_reviewer([0, 1, 1], 1)
    assert round1_runtime_prompt =~ "Check the runtime."
    assert round1_runtime_prompt =~ "artifact:\ndraft-v2"

    await_lease_released(id)

    refute_received {:reviewer_entered, _, %{node_path: [0, 1, 2]}, _}

    committed =
      id
      |> events()
      |> Enum.filter(&(&1.type == :agent_committed))

    assert Enum.map(committed, & &1.payload.address) == [
             [0, 0],
             [0, 1, 0],
             [0, 1, 1],
             [0, 2],
             [0, 1, 0],
             [0, 1, 1]
           ]

    assert Enum.map(committed, & &1.payload.label) == [
             "stable-producer",
             "stable-spec",
             "stable-runtime",
             "stable-reviser",
             "stable-spec",
             "stable-runtime"
           ]

    assert Enum.count(events(id), &(&1.type == :agent_attempt_rejected)) == 2

    prompts =
      id
      |> events()
      |> Enum.filter(&(&1.type in [:agent_committed, :agent_attempt_rejected]))
      |> Enum.map(& &1.payload.prompt)

    refute Enum.any?(prompts, &String.contains?(&1, "Changed"))
    assert Status.of(id).state == :completed
  end

  test "refine reviewer activity is committed only through ordered final role events" do
    id = run_id()

    assert {:ok, ^id} =
             Run.run(InlineConverges,
               run_id: id,
               provider:
                 {RefineProvider,
                  artifact: "draft-v1",
                  reviews: [
                    [approved: true, findings: []],
                    [approved: true, findings: []]
                  ],
                  activity_entries: [%{kind: "note", summary: "reviewing"}],
                  sink: self()}
             )

    refute :agent_activity in types(id)

    reviewer_events =
      id
      |> events()
      |> Enum.filter(&(&1.type == :agent_committed and match?([0, 1, _], &1.payload.address)))

    assert [
             %{payload: %{activity: [%{activity_index: 0, kind: "note", summary: "reviewing"}]}},
             %{payload: %{activity: [%{activity_index: 0, kind: "note", summary: "reviewing"}]}}
           ] = reviewer_events
  end

  test "bound binary artifact input skips inline producer and converges" do
    id = run_id()

    {:ok, script} =
      ScriptedProvider.start([
        "bound draft",
        %{"approved" => true, "findings" => []},
        %{"approved" => true, "findings" => []}
      ])

    assert {:ok, ^id} =
             Run.run(BoundConverges,
               run_id: id,
               provider: {ScriptedProvider, script: script, sink: self()}
             )

    assert_received {:agent_called, "Draft."}
    assert_received {:agent_called, spec_prompt}
    assert_received {:agent_called, runtime_prompt}
    refute_received {:agent_called, "Fix."}
    refute_received {:agent_called, _}

    assert spec_prompt =~ "artifact:\nbound draft"
    assert runtime_prompt =~ "artifact:\nbound draft"

    started = Enum.find(events(id), &(&1.type == :refine_started)).payload
    assert started.input == %{kind: :binding, name: :draft, ref: {:node, [0]}}

    assert types(id) ==
             [
               :run_started,
               :agent_committed,
               :refine_started,
               :refine_round_started,
               :agent_committed,
               :agent_committed,
               :refine_round_decision,
               :refine_completed,
               :run_completed
             ]
  end

  test "bound artifact-object input reviews the inner artifact binary" do
    id = run_id()

    {:ok, script} =
      ScriptedProvider.start([
        %{"artifact" => "object draft"},
        %{"approved" => true, "findings" => []},
        %{"approved" => true, "findings" => []}
      ])

    assert {:ok, ^id} =
             Run.run(BoundArtifactObjectConverges,
               run_id: id,
               provider: {ScriptedProvider, script: script, sink: self()}
             )

    assert_received {:agent_called, "Draft."}
    assert_received {:agent_called, spec_prompt}
    assert_received {:agent_called, runtime_prompt}
    refute_received {:agent_called, "Fix."}
    refute_received {:agent_called, _}

    assert spec_prompt =~ "artifact:\nobject draft"
    assert runtime_prompt =~ "artifact:\nobject draft"

    committed_addresses =
      id
      |> events()
      |> Enum.filter(&(&1.type == :agent_committed))
      |> Enum.map(& &1.payload.address)

    assert committed_addresses == [[0], [1, 1, 0], [1, 1, 1]]
    refute [1, 0] in committed_addresses

    completed = Enum.find(events(id), &(&1.type == :refine_completed)).payload
    assert completed.artifact == "object draft"
    assert completed.converged == true
  end

  test "invalid bound artifact input journals terminal refine failure" do
    id = run_id()

    {:ok, script} =
      ScriptedProvider.start([
        %{"not_artifact" => "value"}
      ])

    assert {:error, {:invalid_refine_input, [1], :artifact_object_unexpected_shape}} =
             Run.run(BoundInvalidObject,
               run_id: id,
               provider: {ScriptedProvider, script: script, sink: self()}
             )

    assert_received {:agent_called, "Draft."}
    refute_received {:agent_called, _}

    assert types(id) == [
             :run_started,
             :agent_committed,
             :refine_started,
             :refine_input_invalid
           ]

    invalid = Enum.find(events(id), &(&1.type == :refine_input_invalid)).payload
    assert invalid.address == [1]
    assert invalid.input == %{kind: :binding, name: :draft, ref: {:node, [0]}}
    assert invalid.reason == :artifact_object_unexpected_shape

    status = Status.of(id)
    assert status.state == :failed

    assert status.failure.reason ==
             {:invalid_refine_input, [1], :artifact_object_unexpected_shape}

    assert {:error, {:invalid_refine_input, [1], :artifact_object_unexpected_shape}} =
             Run.run(BoundInvalidObject,
               run_id: id,
               provider:
                 {RefineProvider,
                  artifact: "unused",
                  reviews: [
                    [approved: true, findings: []],
                    [approved: true, findings: []]
                  ]}
             )
  end

  test "inline producer rejected attempt is journaled before a retry crashes" do
    id = run_id()

    assert {:error, {:run_crashed, _reason}} =
             Run.run(InlineConverges,
               run_id: id,
               provider: {ProducerRetryCrashProvider, sink: self()}
             )

    rejected =
      id
      |> events()
      |> Enum.filter(&(&1.type == :agent_attempt_rejected))

    assert [
             %{
               payload: %{
                 address: [0, 0],
                 iteration: 0,
                 attempt: 0
               }
             }
           ] = rejected

    flush_agent_calls()

    assert {:ok, ^id} =
             Run.run(InlineConverges,
               run_id: id,
               provider:
                 {RefineProvider,
                  artifact: "draft-v1",
                  reviews: [
                    [approved: true, findings: []],
                    [approved: true, findings: []]
                  ],
                  sink: self()}
             )

    assert_received {:agent_called, "Draft.", %{node_path: [0, 0], attempt: 1}}
  end

  test "reviser rejected attempt is journaled before a retry crashes" do
    id = run_id()

    assert {:error, {:run_crashed, _reason}} =
             Run.run(InlineConverges,
               run_id: id,
               provider: {ReviserRetryCrashProvider, sink: self()}
             )

    rejected =
      id
      |> events()
      |> Enum.filter(&(&1.type == :agent_attempt_rejected and &1.payload.address == [0, 2]))

    assert [
             %{
               payload: %{
                 address: [0, 2],
                 iteration: 0,
                 attempt: 0
               }
             }
           ] = rejected

    flush_agent_calls()

    assert {:ok, ^id} =
             Run.run(InlineConverges,
               run_id: id,
               provider:
                 {RefineProvider,
                  artifact: "unused",
                  review_rounds: [
                    [
                      [
                        approved: false,
                        findings: [
                          %{
                            "id" => "spec-gap",
                            "blocking" => true,
                            "issue" => "Spec is ambiguous.",
                            "fix" => "Pin the behavior."
                          }
                        ]
                      ],
                      [approved: true, findings: []]
                    ],
                    [
                      [approved: true, findings: []],
                      [approved: true, findings: []]
                    ]
                  ],
                  revised_artifacts: ["draft-v2"],
                  sink: self()}
             )

    assert_received {:agent_called, reviser_prompt, %{node_path: [0, 2], attempt: 1}}
    assert reviser_prompt =~ "current-artifact:\ndraft-v1"
  end

  test "resume commits producer failure when final rejected attempt was already journaled" do
    id = run_id()
    node = hd(InlineConverges.__workflow__(:tree).nodes)
    {:producer, producer} = node.input
    final_reason = {:property, "artifact", :artifact_not_binary}

    rejected =
      for attempt <- 0..2 do
        reason = if attempt == 2, do: final_reason, else: {:retry, attempt}

        Workflow.Event.agent_attempt_rejected(
          producer,
          0,
          attempt,
          %{"artifact" => 123},
          reason,
          %Usage{}
        )
      end

    append_events(
      id,
      [
        Workflow.Event.run_started(InlineConverges.__workflow__(:tree)),
        Workflow.Event.refine_started(node)
        | rejected
      ]
    )

    assert {:error, {:malformed_output, [0, 0], ^final_reason}} =
             Run.run(InlineConverges, run_id: id, provider: {ExplodingProvider, []})

    assert %{
             payload: %{
               address: [0, 0],
               iteration: 0,
               attempts: 3,
               reason: ^final_reason
             }
           } =
             id
             |> events()
             |> Enum.find(&(&1.type == :agent_failed and &1.payload.address == [0, 0]))

    refute :refine_round_started in types(id)
  end

  test "resume commits reviser failure when final rejected attempt was already journaled" do
    id = run_id()
    node = hd(InlineConverges.__workflow__(:tree).nodes)
    {:producer, producer} = node.input
    [%{agent: spec_reviewer}, %{agent: runtime_reviewer}] = node.reviewers
    reviser = node.reviser
    final_reason = {:property, "artifact", :artifact_not_binary}

    finding = %{
      "id" => "spec-gap",
      "blocking" => true,
      "issue" => "Spec is ambiguous.",
      "fix" => "Pin the behavior."
    }

    open_finding = %{
      reviewer: :spec,
      reviewer_index: 0,
      id: "spec-gap",
      issue: "Spec is ambiguous.",
      fix: "Pin the behavior."
    }

    rejected =
      for attempt <- 0..2 do
        reason = if attempt == 2, do: final_reason, else: {:retry, attempt}

        Workflow.Event.agent_attempt_rejected(
          reviser,
          0,
          attempt,
          %{"artifact" => 123},
          reason,
          %Usage{}
        )
      end

    append_events(
      id,
      [
        Workflow.Event.run_started(InlineConverges.__workflow__(:tree)),
        Workflow.Event.refine_started(node),
        Workflow.Event.agent_committed(
          producer,
          0,
          key(id, [0, 0], 0),
          "draft-v1",
          %Usage{}
        ),
        Workflow.Event.refine_round_started(node, 0, "draft-v1"),
        Workflow.Event.agent_committed(
          spec_reviewer,
          0,
          key(id, [0, 1, 0], 0),
          %{"approved" => false, "findings" => [finding]},
          %Usage{}
        ),
        Workflow.Event.agent_committed(
          runtime_reviewer,
          0,
          key(id, [0, 1, 1], 0),
          %{"approved" => true, "findings" => []},
          %Usage{}
        ),
        Workflow.Event.refine_round_decision(node, 0, %{
          consensus: false,
          approval_count: 1,
          total: 2,
          reviewer_decisions: [
            %{reviewer: :spec, reviewer_index: 0, approved: false, clear: false},
            %{reviewer: :runtime, reviewer_index: 1, approved: true, clear: true}
          ],
          artifact: "draft-v1",
          open_findings: [open_finding]
        })
        | rejected
      ]
    )

    assert {:error, {:malformed_output, [0, 2], ^final_reason}} =
             Run.run(InlineConverges, run_id: id, provider: {ExplodingProvider, []})

    assert %{
             payload: %{
               address: [0, 2],
               iteration: 0,
               attempts: 3,
               reason: ^final_reason
             }
           } =
             id
             |> events()
             |> Enum.find(&(&1.type == :agent_failed and &1.payload.address == [0, 2]))

    refute :refine_non_converged in types(id)
    assert Enum.count(types(id), &(&1 == :refine_round_started)) == 1
  end

  test "resume uses reviewer timeout captured in refine_started payload" do
    id = run_id()
    node = hd(InlineConverges.__workflow__(:tree).nodes)

    started =
      node
      |> Workflow.Event.refine_started()
      |> then(fn event ->
        %{event | payload: Map.put(event.payload, :reviewer_timeout_ms, 5)}
      end)

    append_events(id, [
      Workflow.Event.run_started(InlineConverges.__workflow__(:tree)),
      started
    ])

    previous_timeout = Application.get_env(:codex_loops, :refine_reviewer_timeout)
    Application.put_env(:codex_loops, :refine_reviewer_timeout, 200)

    try do
      assert {:ok, ^id} =
               Run.run(InlineConverges,
                 run_id: id,
                 provider: {SlowReviewerProvider, sink: self()}
               )
    after
      if previous_timeout do
        Application.put_env(:codex_loops, :refine_reviewer_timeout, previous_timeout)
      else
        Application.delete_env(:codex_loops, :refine_reviewer_timeout)
      end
    end

    role_failure = Enum.find(events(id), &(&1.type == :refine_role_failed)).payload
    assert role_failure.reason == {:reviewer_timeout, 5}
    assert role_failure.role_address == [0, 1, 0]
    assert role_failure.reviewer == :spec
    assert Status.of(id).state == :completed
  end

  test "reviewer schema exhaustion records role failure and preserves successful reviewers" do
    id = run_id()

    assert {:ok, ^id} =
             Run.run(InlineConverges,
               run_id: id,
               provider: {ReviewerRoleFailureProvider, failure: :schema, sink: self()}
             )

    assert_received {:agent_called, reviser_prompt, %{node_path: [0, 2], iteration: 0}}
    assert reviser_prompt =~ "reviewer-role-failure-count: 1"
    assert reviser_prompt =~ "role-failure 1:"

    refute Enum.any?(
             events(id),
             &(&1.type == :agent_failed and &1.payload.address == [0, 1, 0])
           )

    role_failure = Enum.find(events(id), &(&1.type == :refine_role_failed)).payload

    assert role_failure == %{
             address: [0],
             role: :reviewer,
             role_address: [0, 1, 0],
             round: 0,
             reviewer: :spec,
             reviewer_index: 0,
             attempts: 1,
             reason: {:malformed_output, {:missing_required, "findings"}},
             detail: {:missing_required, "findings"},
             usage: nil,
             activity: []
           }

    [round0, round1] =
      id
      |> events()
      |> Enum.filter(&(&1.type == :refine_round_decision))
      |> Enum.map(& &1.payload)

    assert round0.consensus == false
    assert round0.approval_count == 1
    assert round0.total == 2
    assert round0.role_failures == [role_failure]
    assert round0.failed_reviewers == [:spec]

    assert round0.reviewer_decisions == [
             %{
               reviewer: :spec,
               reviewer_index: 0,
               approved: false,
               clear: false,
               adapter: :findings_v1,
               status: :failed
             },
             %{
               reviewer: :runtime,
               reviewer_index: 1,
               approved: true,
               clear: true,
               adapter: :findings_v1,
               status: :completed
             }
           ]

    assert round1.consensus == true
    assert round1.role_failures == []
    assert round1.failed_reviewers == []

    completed = Enum.find(events(id), &(&1.type == :refine_completed)).payload
    assert completed.role_failures == []
    assert completed.failed_reviewers == []
    assert completed.artifact == "draft-v2"
    assert Status.of(id).state == :completed
  end

  test "reviewer expected provider failure records role failure usage and activity" do
    id = run_id()
    detail = %{"message" => "provider timeout", "retryable" => true}
    usage = %Usage{input_tokens: 7, output_tokens: 0, total_tokens: 7}

    assert {:ok, ^id} =
             Run.run(InlineConverges,
               run_id: id,
               provider: {ReviewerRoleFailureProvider, failure: :provider_failure, sink: self()}
             )

    role_failure = Enum.find(events(id), &(&1.type == :refine_role_failed)).payload

    assert role_failure.reason == {:provider_failure, :timeout, detail}
    assert role_failure.detail == detail
    assert role_failure.usage == usage

    assert Enum.map(role_failure.activity, &Map.delete(&1, :activity_index)) == [
             %{
               kind: "provider",
               label: "Provider",
               summary: "reviewer timed out",
               status: "failed"
             }
           ]

    assert Ledger.of(id).spent >= usage.total_tokens
    status = Status.of(id)
    assert status.usage.total_tokens >= usage.total_tokens
    assert status.state == :completed
  end

  test "slow reviewer lane times out into an ordered role failure" do
    id = run_id()

    previous_timeout = Application.get_env(:codex_loops, :refine_reviewer_timeout)
    Application.put_env(:codex_loops, :refine_reviewer_timeout, 10)

    try do
      assert {:ok, ^id} =
               Run.run(InlineConverges,
                 run_id: id,
                 provider: {SlowReviewerProvider, sink: self()}
               )
    after
      if previous_timeout do
        Application.put_env(:codex_loops, :refine_reviewer_timeout, previous_timeout)
      else
        Application.delete_env(:codex_loops, :refine_reviewer_timeout)
      end
    end

    assert [
             %{type: :refine_role_failed, payload: %{role_address: [0, 1, 0], attempts: 1}},
             %{type: :agent_committed, payload: %{address: [0, 1, 1]}}
           ] =
             id
             |> events()
             |> Enum.filter(fn
               %{type: :refine_role_failed, payload: payload} ->
                 payload.role_address in [[0, 1, 0]]

               %{type: :agent_committed, payload: payload} ->
                 match?([0, 1, _], payload.address) and payload.iteration == 0

               _event ->
                 false
             end)

    assert Enum.find(events(id), &(&1.type == :refine_started)).payload.reviewer_timeout_ms == 10
    assert :refine_round_decision in types(id)
    assert Status.of(id).state == :completed
  end

  test "hard-killed reviewer lane becomes an ordered role failure without killing the writer" do
    id = run_id()

    assert {:ok, ^id} =
             Run.run(InlineConverges,
               run_id: id,
               provider: {KilledReviewerProvider, sink: self()}
             )

    assert [
             %{
               type: :refine_role_failed,
               payload: %{role_address: [0, 1, 0], reason: {:reviewer_crashed, :killed}}
             },
             %{type: :agent_committed, payload: %{address: [0, 1, 1]}}
           ] =
             id
             |> events()
             |> Enum.filter(fn
               %{type: :refine_role_failed, payload: payload} ->
                 payload.role_address in [[0, 1, 0]]

               %{type: :agent_committed, payload: payload} ->
                 match?([0, 1, _], payload.address) and payload.iteration == 0

               _event ->
                 false
             end)

    assert :refine_round_decision in types(id)
    assert Status.of(id).state == :completed
  end

  test "cold-read and repair gates journal descriptors, role effects, and structured result" do
    id = run_id()

    assert {:ok, ^id} =
             Run.run(GateColdRepairEmitResult,
               run_id: id,
               provider:
                 {RefineProvider,
                  artifact: "draft-v1",
                  reviews: [
                    [
                      approved: false,
                      findings: [
                        %{
                          "id" => "base-gap",
                          "blocking" => true,
                          "issue" => "Base review found a gap.",
                          "fix" => "Repair the base gap."
                        }
                      ]
                    ],
                    [approved: true, findings: []]
                  ],
                  cold_read_review: [
                    approved: false,
                    findings: [
                      %{
                        "id" => "cold-gap",
                        "blocking" => true,
                        "issue" => "Cold read found another gap.",
                        "fix" => "Repair the cold gap."
                      }
                    ]
                  ],
                  repair_artifact: "repaired-v1",
                  sink: self()}
             )

    started = Enum.find(events(id), &(&1.type == :refine_started)).payload
    assert started.gates.cold_read.descriptor.address == [0, 3]
    assert started.gates.cold_read.descriptor.name == :cold
    assert started.gates.repair.descriptor.address == [0, 4]
    assert started.gates.repair.predicate == {:path_non_empty, "/coldRead/openFindings"}

    assert_received {:agent_called, cold_prompt, %{node_path: [0, 3], iteration: 0}}
    assert cold_prompt =~ "--- CODEX LOOPS REFINE COLD READ INPUT ---"
    assert cold_prompt =~ "artifact-bytes: 8\nartifact:\ndraft-v1"
    assert cold_prompt =~ "open-finding-count: 1"
    assert cold_prompt =~ "role-failure-count: 0"
    refute cold_prompt =~ "\"openFindings\""

    assert_received {:agent_called, repair_prompt, %{node_path: [0, 4], iteration: 0}}
    assert repair_prompt =~ "--- CODEX LOOPS REFINE REVISION INPUT ---"
    assert repair_prompt =~ "round: 0"
    assert repair_prompt =~ "blocking-finding-count: 2"
    assert repair_prompt =~ "id:\nbase-gap\n"
    assert repair_prompt =~ "id:\ncold-gap\n"
    refute repair_prompt =~ "--- CODEX LOOPS REFINE REPAIR INPUT ---"

    gate_events = Enum.filter(events(id), &(&1.type == :refine_gate_evaluated))
    assert Enum.map(gate_events, & &1.payload.gate) == [:cold_read, :repair]
    assert Enum.all?(gate_events, & &1.payload.result)
    assert Enum.all?(gate_events, &(&1.payload.input_round == 0))

    completed = Enum.find(events(id), &(&1.type == :refine_completed)).payload
    assert completed.artifact == "repaired-v1"
    assert completed.cold_read.state == :completed
    assert completed.cold_read.repaired == true

    assert completed.cold_read.open_findings == [
             %{
               reviewer: :cold,
               reviewer_index: nil,
               id: "cold-gap",
               issue: "Cold read found another gap.",
               fix: "Repair the cold gap."
             }
           ]

    result = Enum.find(events(id), &(&1.type == :run_completed)).payload.value
    assert result["artifact"] == "repaired-v1"
    assert result["coldRead"]["state"] == "completed"
    assert result["coldRead"]["repaired"] == true
    assert [%{"id" => "cold-gap"}] = result["coldRead"]["openFindings"]

    assert result["rawRefs"]["journal"]
           |> Enum.map(&{&1["type"], &1["address"]})
           |> Enum.any?(&(&1 == {"agent_committed", [0, 3]}))

    assert result["rawRefs"]["journal"]
           |> Enum.map(&{&1["type"], &1["address"]})
           |> Enum.any?(&(&1 == {"agent_committed", [0, 4]}))

    assert Ledger.of(id).spent == 10
  end

  test "cold-read timeout and hard crash become role failures without killing the writer" do
    previous_timeout = Application.get_env(:codex_loops, :refine_reviewer_timeout)
    Application.put_env(:codex_loops, :refine_reviewer_timeout, 10)

    try do
      timeout_id = run_id()

      assert {:ok, ^timeout_id} =
               Run.run(GateColdRepairEmitResult,
                 run_id: timeout_id,
                 provider: {ColdReadLaneFailureProvider, failure: :timeout, sink: self()}
               )

      timeout_failure =
        timeout_id
        |> events()
        |> Enum.find(&(&1.type == :refine_role_failed))
        |> then(& &1.payload)

      assert timeout_failure.role == :cold_read
      assert timeout_failure.role_address == [0, 3]
      assert timeout_failure.reason == {:cold_read_timeout, 10}
      assert Status.of(timeout_id).state == :completed

      killed_id = run_id()

      assert {:ok, ^killed_id} =
               Run.run(GateColdRepairEmitResult,
                 run_id: killed_id,
                 provider: {ColdReadLaneFailureProvider, failure: :killed, sink: self()}
               )

      killed_failure =
        killed_id
        |> events()
        |> Enum.find(&(&1.type == :refine_role_failed))
        |> then(& &1.payload)

      assert killed_failure.role == :cold_read
      assert killed_failure.role_address == [0, 3]
      assert killed_failure.reason == {:cold_read_crashed, :killed}
      assert Status.of(killed_id).state == :completed
    after
      if previous_timeout do
        Application.put_env(:codex_loops, :refine_reviewer_timeout, previous_timeout)
      else
        Application.delete_env(:codex_loops, :refine_reviewer_timeout)
      end
    end
  end

  test "repair gate replay turns exhausted rejected attempts into one role failure" do
    id = run_id()
    tree = GateRepairReplayExhausted.__workflow__(:tree)
    node = hd(tree.nodes)

    open_findings = [
      %{
        reviewer: :spec,
        reviewer_index: 0,
        id: "base-gap",
        issue: "Base review found a gap.",
        fix: "Repair the base gap."
      }
    ]

    repair_agent = %Workflow.Node.Agent{address: [0, 4], prompt: "Repair.", retries: 2}

    append_events(id, [
      Workflow.Event.run_started(tree),
      Workflow.Event.refine_started(node),
      Workflow.Event.agent_committed(
        %Workflow.Node.Agent{address: [0, 0], prompt: "Draft."},
        0,
        key(id, [0, 0], 0),
        "draft-v1",
        %Usage{}
      ),
      Workflow.Event.refine_round_started(node, 0, "draft-v1"),
      Workflow.Event.refine_round_decision(node, 0, %{
        consensus: false,
        approval_count: 1,
        total: 2,
        reviewer_decisions: [
          %{
            reviewer: :spec,
            reviewer_index: 0,
            approved: false,
            clear: false,
            adapter: :findings_v1,
            status: :completed
          },
          %{
            reviewer: :runtime,
            reviewer_index: 1,
            approved: true,
            clear: true,
            adapter: :findings_v1,
            status: :completed
          }
        ],
        artifact: "draft-v1",
        open_findings: open_findings,
        role_failures: [],
        failed_reviewers: [],
        report_snippets: []
      }),
      Workflow.Event.refine_gate_evaluated(node, :repair, {:path_non_empty, "/openFindings"},
        result: true,
        input_round: 0,
        input_refs: []
      ),
      Workflow.Event.agent_attempt_rejected(
        repair_agent,
        0,
        0,
        %{"artifact" => 123},
        :artifact_not_binary,
        %Usage{input_tokens: 1, output_tokens: 0, total_tokens: 1}
      ),
      Workflow.Event.agent_attempt_rejected(
        repair_agent,
        0,
        1,
        %{"artifact" => 123},
        :artifact_not_binary,
        %Usage{input_tokens: 1, output_tokens: 0, total_tokens: 1}
      ),
      Workflow.Event.agent_attempt_rejected(
        repair_agent,
        0,
        2,
        %{"artifact" => 123},
        :artifact_not_binary,
        %Usage{input_tokens: 1, output_tokens: 0, total_tokens: 1}
      )
    ])

    assert {:ok, ^id} =
             Run.run(GateRepairReplayExhausted,
               run_id: id,
               provider: {ExplodingProvider, []}
             )

    role_failures = Enum.filter(events(id), &(&1.type == :refine_role_failed))
    assert length(role_failures) == 1

    assert hd(role_failures).payload.reason == {:repair_failed, :artifact_not_binary}
    assert hd(role_failures).payload.role == :repair
    assert hd(role_failures).payload.role_address == [0, 4]
    assert hd(role_failures).payload.attempts == 3
    assert Status.of(id).state == :completed
  end

  test "halt gate wins over accept_current completion with pinned gate reason" do
    id = run_id()
    predicate = {:path_non_empty, "/openFindings"}

    assert {:error, {:did_not_converge, [0], {:gate, ^predicate}}} =
             Run.run(GateHaltAcceptCurrent,
               run_id: id,
               provider:
                 {RefineProvider,
                  artifact: "draft-v1",
                  reviews: [
                    [
                      approved: false,
                      findings: [
                        %{
                          "id" => "still-bad",
                          "blocking" => true,
                          "issue" => "Still bad.",
                          "fix" => "Fix it."
                        }
                      ]
                    ],
                    [approved: true, findings: []]
                  ],
                  sink: self()}
             )

    refute :refine_completed in types(id)
    refute :run_completed in types(id)

    non_converged = Enum.find(events(id), &(&1.type == :refine_non_converged)).payload
    assert non_converged.reason == {:gate, predicate}
    assert Status.of(id).failure.reason == {:did_not_converge, [0], {:gate, predicate}}
  end

  test "journaled gate decisions replay instead of recomputing edited predicates" do
    id = run_id()
    tree = GateReplayColdTrue.__workflow__(:tree)
    node = hd(tree.nodes)

    key = fn address ->
      %Workflow.IdempotencyKey{run_id: id, node_path: address, iteration: 0, attempt: 0}
    end

    open_findings = [
      %{
        reviewer: :spec,
        reviewer_index: 0,
        id: "base-gap",
        issue: "Base review found a gap.",
        fix: "Repair the base gap."
      }
    ]

    seeded = [
      Workflow.Event.run_started(tree),
      Workflow.Event.refine_started(node),
      Workflow.Event.agent_committed(
        %Workflow.Node.Agent{address: [0, 0], prompt: "Draft."},
        0,
        key.([0, 0]),
        "draft-v1",
        %Usage{}
      ),
      Workflow.Event.refine_round_started(node, 0, "draft-v1"),
      Workflow.Event.agent_committed(
        %Workflow.Node.Agent{address: [0, 1, 0], prompt: "Check the spec."},
        0,
        key.([0, 1, 0]),
        %{"approved" => false, "findings" => []},
        %Usage{}
      ),
      Workflow.Event.agent_committed(
        %Workflow.Node.Agent{address: [0, 1, 1], prompt: "Check the runtime."},
        0,
        key.([0, 1, 1]),
        %{"approved" => true, "findings" => []},
        %Usage{}
      ),
      Workflow.Event.refine_round_decision(node, 0, %{
        consensus: false,
        approval_count: 1,
        total: 2,
        reviewer_decisions: [
          %{
            reviewer: :spec,
            reviewer_index: 0,
            approved: false,
            clear: false,
            adapter: :findings_v1,
            status: :completed
          },
          %{
            reviewer: :runtime,
            reviewer_index: 1,
            approved: true,
            clear: true,
            adapter: :findings_v1,
            status: :completed
          }
        ],
        artifact: "draft-v1",
        open_findings: open_findings,
        role_failures: [],
        failed_reviewers: [],
        report_snippets: []
      }),
      Workflow.Event.refine_gate_evaluated(node, :cold_read, {:path_non_empty, "/openFindings"},
        result: true,
        input_round: 0,
        input_refs: []
      )
    ]

    Enum.reduce(seeded, 0, fn event, seq ->
      assert :ok = Journal.append(id, seq, event)
      seq + 1
    end)

    assert {:ok, ^id} =
             Run.run(GateReplayColdFalseEdit,
               run_id: id,
               provider:
                 {RefineProvider,
                  artifact: "unused",
                  reviews: [
                    [approved: true, findings: []],
                    [approved: true, findings: []]
                  ],
                  cold_read_review: [approved: true, findings: []],
                  sink: self()}
             )

    assert_received {:agent_called, cold_prompt, %{node_path: [0, 3], iteration: 0}}
    assert cold_prompt =~ "Journaled cold read."
    refute cold_prompt =~ "Changed cold read."

    assert Enum.count(types(id), &(&1 == :refine_gate_evaluated)) == 1

    assert Enum.find(events(id), &(&1.type == :refine_completed)).payload.cold_read.state ==
             :completed
  end

  test "non-convergence fail mode journals terminal refine_non_converged and resumes same error" do
    id = run_id()

    assert {:error, {:did_not_converge, [0], :max_rounds}} =
             Run.run(NonConvergesFail,
               run_id: id,
               provider:
                 {RefineProvider,
                  artifact: "draft-v1",
                  reviews: [
                    [
                      approved: false,
                      findings: [
                        %{
                          "id" => "still-bad",
                          "blocking" => true,
                          "issue" => "Still bad.",
                          "fix" => "Fix it."
                        }
                      ]
                    ],
                    [approved: true, findings: []]
                  ],
                  sink: self()}
             )

    assert :refine_non_converged in types(id)
    refute :run_completed in types(id)
    assert Status.of(id).state == :failed
    assert Status.of(id).failure.reason == {:did_not_converge, [0], :max_rounds}
    assert Status.of(id).failure.attempts == 0

    flush_agent_calls()

    assert {:error, {:did_not_converge, [0], :max_rounds}} =
             Run.run(NonConvergesFail,
               run_id: id,
               provider:
                 {RefineProvider,
                  artifact: "unused",
                  reviews: [
                    [approved: true, findings: []],
                    [approved: true, findings: []]
                  ],
                  sink: self()}
             )

    refute_received {:agent_called, _, _}
  end

  test "non-convergence accept_current commits unconverged artifact and completes" do
    id = run_id()

    assert {:ok, ^id} =
             Run.run(NonConvergesAccept,
               run_id: id,
               provider:
                 {RefineProvider,
                  artifact: "draft-v1",
                  reviews: [
                    [
                      approved: false,
                      findings: [
                        %{
                          "id" => "still-bad",
                          "blocking" => true,
                          "issue" => "Still bad.",
                          "fix" => "Fix it."
                        }
                      ]
                    ],
                    [approved: true, findings: []]
                  ],
                  sink: self()}
             )

    refute :refine_non_converged in types(id)
    assert :run_completed in types(id)

    completed = Enum.find(events(id), &(&1.type == :refine_completed)).payload
    assert completed.converged == false
    assert completed.artifact == "draft-v1"

    assert completed.open_findings == [
             %{
               reviewer: :spec,
               reviewer_index: 0,
               id: "still-bad",
               issue: "Still bad.",
               fix: "Fix it."
             }
           ]
  end

  test "accept_current refine output is bindable and renderable through emit" do
    id = run_id()

    assert {:ok, ^id} =
             Run.run(AcceptCurrentEmit,
               run_id: id,
               provider:
                 {RefineProvider,
                  artifact: "draft-v1",
                  reviews: [
                    [
                      approved: false,
                      findings: [
                        %{
                          "id" => "still-bad",
                          "blocking" => true,
                          "issue" => "Still bad.",
                          "fix" => "Fix it."
                        }
                      ]
                    ],
                    [approved: true, findings: []]
                  ],
                  sink: self()}
             )

    assert Enum.find(events(id), &(&1.type == :run_completed)).payload.value == "Final: draft-v1"
    assert Status.of(id).result == "Final: draft-v1"
  end

  test "resume reuses journaled refine markers without duplicating structural events" do
    id = run_id()

    key = fn address ->
      %Workflow.IdempotencyKey{run_id: id, node_path: address, iteration: 0, attempt: 0}
    end

    events = [
      Workflow.Event.run_started(InlineConverges.__workflow__(:tree)),
      Workflow.Event.refine_started(hd(InlineConverges.__workflow__(:tree).nodes)),
      Workflow.Event.agent_committed(
        %Workflow.Node.Agent{address: [0, 0], prompt: "Draft."},
        0,
        key.([0, 0]),
        "draft-v1",
        %Usage{}
      ),
      Workflow.Event.refine_round_started(
        hd(InlineConverges.__workflow__(:tree).nodes),
        0,
        "draft-v1"
      ),
      Workflow.Event.agent_committed(
        %Workflow.Node.Agent{address: [0, 1, 0], prompt: "Check the spec."},
        0,
        key.([0, 1, 0]),
        %{"approved" => true, "findings" => []},
        %Usage{}
      ),
      Workflow.Event.agent_committed(
        %Workflow.Node.Agent{address: [0, 1, 1], prompt: "Check the runtime."},
        0,
        key.([0, 1, 1]),
        %{"approved" => true, "findings" => []},
        %Usage{}
      ),
      Workflow.Event.refine_round_decision(hd(InlineConverges.__workflow__(:tree).nodes), 0, %{
        consensus: true,
        approval_count: 2,
        total: 2,
        reviewer_decisions: [
          %{reviewer: :spec, reviewer_index: 0, approved: true, clear: true},
          %{reviewer: :runtime, reviewer_index: 1, approved: true, clear: true}
        ],
        artifact: "draft-v1",
        open_findings: []
      }),
      Workflow.Event.refine_completed(hd(InlineConverges.__workflow__(:tree).nodes), %{
        converged: true,
        final_round: 0,
        rounds: 1,
        artifact: "draft-v1",
        open_findings: []
      })
    ]

    Enum.reduce(events, 0, fn event, seq ->
      assert :ok = Journal.append(id, seq, event)
      seq + 1
    end)

    assert {:ok, ^id} =
             Run.run(InlineConverges,
               run_id: id,
               provider:
                 {RefineProvider,
                  artifact: "unused",
                  reviews: [
                    [approved: true, findings: []],
                    [approved: true, findings: []]
                  ],
                  sink: self()}
             )

    refute_received {:agent_called, _, _}

    assert Enum.count(types(id), &(&1 == :refine_round_started)) == 1
    assert Enum.count(types(id), &(&1 == :refine_round_decision)) == 1
    assert Enum.count(types(id), &(&1 == :refine_completed)) == 1
    assert List.last(types(id)) == :run_completed
  end
end
