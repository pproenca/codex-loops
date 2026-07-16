defmodule Workflow.RefineRunTest do
  use ExUnit.Case, async: false

  alias Workflow.Event.Payload
  alias Workflow.Journal
  alias Workflow.Ledger
  alias Workflow.Provider.Activity
  alias Workflow.Provider.Usage
  alias Workflow.Refine.OpenFinding
  alias Workflow.Refine.ReviewerDecision
  alias Workflow.Refine.RoundDecision
  alias Workflow.Refine.TerminalProjection
  alias Workflow.Run
  alias Workflow.Status
  alias Workflow.Test.ExplodingProvider
  alias Workflow.Test.RefineProvider
  alias Workflow.Test.ScriptedProvider

  @moduletag :capture_log
  defp activity_fields(%Activity{} = activity) do
    activity
    |> Map.from_struct()
    |> Map.delete(:activity_index)
  end

  defp open_finding!(attrs), do: struct!(OpenFinding, attrs)

  defp reviewer_decision!(attrs) do
    attrs
    |> Map.put_new(:adapter, :findings_v1)
    |> then(&struct!(ReviewerDecision, &1))
  end

  defp round_decision!(attrs) do
    defaults = %{role_failures: [], failed_reviewers: [], report_snippets: []}
    struct!(RoundDecision, Map.merge(defaults, attrs))
  end

  defp terminal_projection!(attrs) do
    defaults = %{
      role_failures: [],
      failed_reviewers: [],
      reviewer_decisions: [],
      report_snippets: [],
      cold_read: nil
    }

    struct!(TerminalProjection, Map.merge(defaults, attrs))
  end

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
            Process.sleep(1_000)
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
                Process.sleep(1_000)
                %{"approved" => true, "findings" => []}

              :killed ->
                Process.exit(self(), :kill)
            end
        end

      {:ok, output, %Usage{input_tokens: 1, output_tokens: 1, total_tokens: 2}}
    end
  end

  defmodule AmbiguousRefineProvider do
    @moduledoc false
    @behaviour Workflow.Provider

    @detail %{"message" => "Codex app-server transport was lost"}

    @impl true
    def run_agent(_prompt, _schema, key, opts) do
      if key.node_path == Keyword.fetch!(opts, :ambiguous_at) do
        exit({:codex_turn_outcome_unknown, @detail})
      end

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

          [0, 1, _reviewer_index] ->
            %{"approved" => true, "findings" => []}

          [0, 2] ->
            %{"artifact" => "draft-v2"}

          [0, 3] ->
            %{"approved" => true, "findings" => []}

          [0, 4] ->
            %{"artifact" => "repaired-v1"}
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

    def tree do
      Workflow.Test.tree!(
        "inline-converges",
        quote do
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
        end,
        __ENV__
      )
    end
  end

  defmodule SequentialReviewerConverges do
    @moduledoc false

    def tree do
      Workflow.Test.tree!(
        "sequential-reviewer-converges",
        quote do
          refine(agent("Draft."),
            reviewers: [
              reviewer(:spec, "Check the spec."),
              reviewer(:runtime, "Check the runtime.")
            ],
            revise_with: agent("Fix."),
            until: :unanimous,
            max_rounds: 1,
            max_concurrency: 1
          )

          return(:ok)
        end,
        __ENV__
      )
    end
  end

  defmodule BlockingReviewerActivityProvider do
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
            activity_sink = Keyword.fetch!(opts, :activity_sink)

            activity_sink.(%{
              kind: "reasoning",
              label: "Reasoning",
              summary: "reviewing draft-v1",
              status: "running"
            })

            send(sink, {:reviewer_waiting, self(), key})

            receive do
              :proceed -> :ok
            after
              5_000 -> raise "reviewer was not released"
            end

            %{"approved" => true, "findings" => []}

          [0, 1, 1] ->
            %{"approved" => true, "findings" => []}
        end

      {:ok, output, %Usage{input_tokens: 1, output_tokens: 1, total_tokens: 2}}
    end
  end

  defmodule ChangedInlineConverges do
    @moduledoc false

    def tree do
      Workflow.Test.tree!(
        "changed-inline-converges",
        quote do
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
        end,
        __ENV__
      )
    end
  end

  defmodule BoundConverges do
    @moduledoc false

    def tree do
      Workflow.Test.tree!(
        "bound-converges",
        quote do
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
        end,
        __ENV__
      )
    end
  end

  defmodule BoundInvalidObject do
    @moduledoc false

    def tree do
      Workflow.Test.tree!(
        "bound-invalid-object",
        quote do
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
        end,
        __ENV__
      )
    end
  end

  defmodule BoundArtifactObjectConverges do
    @moduledoc false

    def tree do
      Workflow.Test.tree!(
        "bound-artifact-object-converges",
        quote do
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
        end,
        __ENV__
      )
    end
  end

  defmodule NonConvergesFail do
    @moduledoc false

    def tree do
      Workflow.Test.tree!(
        "non-converges-fail",
        quote do
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
        end,
        __ENV__
      )
    end
  end

  defmodule NonConvergesAccept do
    @moduledoc false

    def tree do
      Workflow.Test.tree!(
        "non-converges-accept",
        quote do
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
        end,
        __ENV__
      )
    end
  end

  defmodule AdapterConverges do
    @moduledoc false

    def tree do
      Workflow.Test.tree!(
        "adapter-converges",
        quote do
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
        end,
        __ENV__
      )
    end
  end

  defmodule AcceptCurrentEmit do
    @moduledoc false

    def tree do
      Workflow.Test.tree!(
        "accept-current-emit",
        quote do
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
        end,
        __ENV__
      )
    end
  end

  defmodule GateColdRepairEmitResult do
    @moduledoc false

    def tree do
      Workflow.Test.tree!(
        "gate-cold-repair-emit-result",
        quote do
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
        end,
        __ENV__
      )
    end
  end

  defmodule GateHaltAcceptCurrent do
    @moduledoc false

    def tree do
      Workflow.Test.tree!(
        "gate-halt-accept-current",
        quote do
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
        end,
        __ENV__
      )
    end
  end

  defmodule GateRepairReplayExhausted do
    @moduledoc false

    def tree do
      Workflow.Test.tree!(
        "gate-repair-replay-exhausted",
        quote do
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
        end,
        __ENV__
      )
    end
  end

  defmodule GateReplayColdTrue do
    @moduledoc false

    def tree do
      Workflow.Test.tree!(
        "gate-replay-cold-true",
        quote do
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
        end,
        __ENV__
      )
    end
  end

  defmodule GateReplayColdFalseEdit do
    @moduledoc false

    def tree do
      Workflow.Test.tree!(
        "gate-replay-cold-false-edit",
        quote do
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
        end,
        __ENV__
      )
    end
  end

  defp run_id, do: "run_#{System.unique_integer([:positive])}"
  defp events(id), do: Journal.fold(id)

  defp types(id) do
    id
    |> events()
    |> Enum.reject(&(&1.type == :agent_started))
    |> Enum.map(& &1.type)
  end

  defp flush_agent_calls do
    receive do
      {:agent_called, _, _} -> flush_agent_calls()
      {:agent_called, _} -> flush_agent_calls()
    after
      0 -> :ok
    end
  end

  defp wait_for_journal_event(run_id, predicate, tries \\ 100)

  defp wait_for_journal_event(run_id, predicate, tries) when tries > 0 do
    case Enum.find(events(run_id), predicate) do
      nil ->
        Process.sleep(10)
        wait_for_journal_event(run_id, predicate, tries - 1)

      event ->
        event
    end
  end

  defp wait_for_journal_event(run_id, _predicate, 0), do: flunk("expected matching journal event for #{run_id}")

  defp stable_refine_started_event(node) do
    event = Workflow.Event.refine_started(node)
    {:producer, producer} = event.payload.input

    reviewers =
      Enum.map(event.payload.reviewers, fn reviewer ->
        %{reviewer | agent: %{reviewer.agent | label: "stable-#{reviewer.name}"}}
      end)

    %{
      event
      | payload: %{
          event.payload
          | input: {:producer, %{producer | retries: 1, label: "stable-producer"}},
            reviewers: reviewers,
            reviser: %{event.payload.reviser | retries: 1, label: "stable-reviser"},
            max_concurrency: 1
        }
    }
  end

  defp append_events(id, journal_events) do
    _next_seq =
      Enum.reduce(journal_events, 0, fn event, seq ->
        assert {:ok, %{seq: ^seq}} = Journal.append_next(id, event)
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

  test "inline producer converges in round 0 without invoking the reviser" do
    id = run_id()

    assert {:ok, ^id} =
             Run.run(InlineConverges.tree(),
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

    assert %Payload.RefineRoundDecision{
             address: [0],
             round: 0,
             consensus: true,
             approval_count: 2,
             total: 2,
             artifact: "draft-v1",
             open_findings: [],
             reviewer_decisions: [
               %ReviewerDecision{
                 reviewer: :spec,
                 reviewer_index: 0,
                 adapter: :findings_v1,
                 outcome: :clear
               },
               %ReviewerDecision{
                 reviewer: :runtime,
                 reviewer_index: 1,
                 adapter: :findings_v1,
                 outcome: :clear
               }
             ],
             role_failures: [],
             failed_reviewers: [],
             report_snippets: []
           } = decision

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
             Run.run(AdapterConverges.tree(),
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

    assert Enum.map(decision.reviewer_decisions, &{&1.reviewer, &1.adapter, &1.outcome}) ==
             [
               {:findings, :findings_v1, :clear},
               {:defects, :defects_v1, :clear},
               {:violations, :violations_v1, :clear},
               {:concerns, :concerns_v1, :clear}
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
             Run.run(InlineConverges.tree(),
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
             Run.run(NonConvergesAccept.tree(),
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
             %OpenFinding{
               reviewer: :spec,
               reviewer_index: 0,
               id: "a-first",
               issue: "first sorted issue",
               fix: "first sorted fix"
             },
             %OpenFinding{
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
    node = hd(InlineConverges.tree().nodes)

    key = fn address, iteration ->
      %Workflow.IdempotencyKey{run_id: id, node_path: address, iteration: iteration, attempt: 0}
    end

    prior_events = [
      Workflow.Event.run_started(InlineConverges.tree()),
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
      Workflow.Event.refine_round_decision(
        node,
        0,
        round_decision!(%{
          consensus: false,
          approval_count: 1,
          total: 2,
          reviewer_decisions: [
            reviewer_decision!(%{reviewer: :spec, reviewer_index: 0, outcome: :rejected}),
            reviewer_decision!(%{reviewer: :runtime, reviewer_index: 1, outcome: :clear})
          ],
          artifact: "draft-v1",
          open_findings: [
            open_finding!(%{
              reviewer: :spec,
              reviewer_index: 0,
              id: "spec-gap",
              issue: "Spec is ambiguous.",
              fix: "Pin the behavior."
            })
          ]
        })
      ),
      Workflow.Event.agent_committed(
        %Workflow.Node.Agent{address: [0, 2], prompt: "Fix."},
        0,
        key.([0, 2], 0),
        "draft-v2",
        %Usage{}
      )
    ]

    Enum.reduce(prior_events, 0, fn event, seq ->
      assert {:ok, %{seq: ^seq}} = Journal.append_next(id, event)
      seq + 1
    end)

    assert {:ok, ^id} =
             Run.run(InlineConverges.tree(),
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

  test "resume rejects changed compiled refine descriptors before replay" do
    id = run_id()
    node = hd(InlineConverges.tree().nodes)

    prior_events = [
      Workflow.Event.run_started(InlineConverges.tree()),
      stable_refine_started_event(node)
    ]

    Enum.reduce(prior_events, 0, fn event, seq ->
      assert {:ok, %{seq: ^seq}} = Journal.append_next(id, event)
      seq + 1
    end)

    before_events = events(id)

    assert {:error, {:tree_fingerprint_mismatch, _recorded, _current}} =
             Run.start(ChangedInlineConverges.tree(),
               run_id: id,
               provider: {ReplayStartedProvider, sink: self()}
             )

    assert events(id) == before_events
    refute_received {:agent_called, _, _}
  end

  test "refine reviewer activity is durably streamed without terminal-event duplication" do
    id = run_id()

    assert {:ok, ^id} =
             Run.run(InlineConverges.tree(),
               run_id: id,
               provider:
                 {RefineProvider,
                  artifact: "draft-v1",
                  reviews: [
                    [approved: true, findings: []],
                    [approved: true, findings: []]
                  ],
                  activity_entries: [
                    %{
                      kind: "note",
                      label: "Review",
                      summary: "reviewing",
                      status: :running
                    }
                  ],
                  sink: self()}
             )

    streamed =
      id
      |> events()
      |> Enum.filter(&(&1.type == :agent_activity and match?([0, 1, _], &1.payload.address)))
      |> Enum.sort_by(& &1.payload.address)

    assert [
             %{payload: %{address: [0, 1, 0], iteration: 0, attempt: 0, activity_index: 0}},
             %{payload: %{address: [0, 1, 1], iteration: 0, attempt: 0, activity_index: 0}}
           ] = streamed

    assert Enum.all?(streamed, fn event ->
             assert %Activity{
                      kind: "note",
                      label: "Review",
                      summary: "reviewing",
                      status: :running
                    } = event.payload.entry
           end)

    reviewer_events =
      id
      |> events()
      |> Enum.filter(&(&1.type == :agent_committed and match?([0, 1, _], &1.payload.address)))

    assert Enum.all?(reviewer_events, &(&1.payload.activity == []))
  end

  test "refine reviewer activity persists before reviewer settlement" do
    id = run_id()

    assert {:ok, ^id, writer} =
             Run.start(SequentialReviewerConverges.tree(),
               run_id: id,
               provider: {BlockingReviewerActivityProvider, sink: self()}
             )

    assert_receive {:reviewer_waiting, reviewer, %{node_path: [0, 1, 0], iteration: 0, attempt: 0}}, 1_000

    activity =
      wait_for_journal_event(id, fn
        %{type: :agent_activity, payload: %{address: [0, 1, 0]}} -> true
        _event -> false
      end)

    assert %{
             address: [0, 1, 0],
             iteration: 0,
             attempt: 0,
             activity_index: 0,
             entry: %{
               kind: "reasoning",
               label: "Reasoning",
               summary: "reviewing draft-v1",
               status: :running
             }
           } = activity.payload

    refute Enum.any?(
             events(id),
             &(&1.type == :agent_committed and &1.payload.address == [0, 1, 0])
           )

    assert Enum.any?(Status.of(id).agents, fn
             %{address: [0, 1, 0], status: :running, activity: [%{summary: "reviewing draft-v1"}]} ->
               true

             _agent ->
               false
           end)

    ref = Process.monitor(writer)
    send(reviewer, :proceed)
    assert_receive {:DOWN, ^ref, :process, ^writer, :normal}, 5_000

    assert Enum.any?(
             events(id),
             &(&1.type == :agent_committed and &1.payload.address == [0, 1, 0])
           )

    assert Status.of(id).state == :completed
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
             Run.run(BoundConverges.tree(),
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
    assert started.input == {:binding, :draft, {:node, [0]}}

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
             Run.run(BoundArtifactObjectConverges.tree(),
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
             Run.run(BoundInvalidObject.tree(),
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
             Run.run(BoundInvalidObject.tree(),
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

  test "inline producer retry crashes leave a durable unknown-outcome marker" do
    id = run_id()

    assert {:error, {:run_crashed, _reason}} =
             Run.run(InlineConverges.tree(),
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

    assert {:error, {:outcome_unknown, %{address: [0, 0], iteration: 0, attempt: 1}}} =
             Run.run(InlineConverges.tree(),
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

    refute_received {:agent_called, _prompt, _key}
    assert Status.of(id).state == :failed
  end

  test "reviser retry crashes leave a durable unknown-outcome marker" do
    id = run_id()

    assert {:error, {:run_crashed, _reason}} =
             Run.run(InlineConverges.tree(),
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

    assert {:error, {:outcome_unknown, %{address: [0, 2], iteration: 0, attempt: 1}}} =
             Run.run(InlineConverges.tree(),
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

    refute_received {:agent_called, _prompt, _key}
    assert Status.of(id).state == :failed
  end

  test "resume commits producer failure when final rejected attempt was already journaled" do
    id = run_id()
    node = hd(InlineConverges.tree().nodes)
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
        Workflow.Event.run_started(InlineConverges.tree()),
        Workflow.Event.refine_started(node)
        | rejected
      ]
    )

    assert {:error, {:malformed_output, [0, 0], ^final_reason}} =
             Run.run(InlineConverges.tree(), run_id: id, provider: {ExplodingProvider, []})

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
    node = hd(InlineConverges.tree().nodes)
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

    open_finding =
      open_finding!(%{
        reviewer: :spec,
        reviewer_index: 0,
        id: "spec-gap",
        issue: "Spec is ambiguous.",
        fix: "Pin the behavior."
      })

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
        Workflow.Event.run_started(InlineConverges.tree()),
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
        Workflow.Event.refine_round_decision(
          node,
          0,
          round_decision!(%{
            consensus: false,
            approval_count: 1,
            total: 2,
            reviewer_decisions: [
              reviewer_decision!(%{reviewer: :spec, reviewer_index: 0, outcome: :rejected}),
              reviewer_decision!(%{reviewer: :runtime, reviewer_index: 1, outcome: :clear})
            ],
            artifact: "draft-v1",
            open_findings: [open_finding]
          })
        )
        | rejected
      ]
    )

    assert {:error, {:malformed_output, [0, 2], ^final_reason}} =
             Run.run(InlineConverges.tree(), run_id: id, provider: {ExplodingProvider, []})

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
    node = hd(InlineConverges.tree().nodes)

    started =
      node
      |> Workflow.Event.refine_started()
      |> then(fn event ->
        %{event | payload: Map.put(event.payload, :reviewer_timeout_ms, 100)}
      end)

    append_events(id, [
      Workflow.Event.run_started(InlineConverges.tree()),
      started
    ])

    previous_timeout = Application.get_env(:codex_loops, :refine_reviewer_timeout)
    Application.put_env(:codex_loops, :refine_reviewer_timeout, 200)

    try do
      assert {:ok, ^id} =
               Run.run(InlineConverges.tree(),
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
    assert role_failure.reason == {:reviewer_timeout, 100}
    assert role_failure.role_address == [0, 1, 0]
    assert role_failure.reviewer == :spec
    assert Status.of(id).state == :completed
  end

  test "reviewer schema exhaustion records role failure and preserves successful reviewers" do
    id = run_id()

    assert {:ok, ^id} =
             Run.run(InlineConverges.tree(),
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

    assert %Payload.RefineRoleFailed{
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
           } = role_failure

    [round0, round1] =
      id
      |> events()
      |> Enum.filter(&(&1.type == :refine_round_decision))
      |> Enum.map(& &1.payload)

    assert round0.consensus == false
    assert round0.approval_count == 1
    assert round0.total == 2
    assert round0.role_failures == [Payload.RefineRoleFailed.role_failure(role_failure)]
    assert round0.failed_reviewers == [:spec]

    assert round0.reviewer_decisions == [
             %ReviewerDecision{
               reviewer: :spec,
               reviewer_index: 0,
               adapter: :findings_v1,
               outcome: :failed
             },
             %ReviewerDecision{
               reviewer: :runtime,
               reviewer_index: 1,
               adapter: :findings_v1,
               outcome: :clear
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
             Run.run(InlineConverges.tree(),
               run_id: id,
               provider: {ReviewerRoleFailureProvider, failure: :provider_failure, sink: self()}
             )

    role_failure = Enum.find(events(id), &(&1.type == :refine_role_failed)).payload

    assert role_failure.reason == {:provider_failure, :timeout, detail}
    assert role_failure.detail == detail
    assert role_failure.usage == usage

    assert Enum.map(role_failure.activity, &activity_fields/1) == [
             %{
               kind: "provider",
               label: "Provider",
               summary: "reviewer timed out",
               status: :failed
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
    Application.put_env(:codex_loops, :refine_reviewer_timeout, 100)

    try do
      assert {:ok, ^id} =
               Run.run(InlineConverges.tree(),
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

    assert Enum.find(events(id), &(&1.type == :refine_started)).payload.reviewer_timeout_ms == 100
    assert :refine_round_decision in types(id)
    assert Status.of(id).state == :completed
  end

  test "hard-killed reviewer lane becomes an ordered role failure without killing the writer" do
    id = run_id()

    assert {:ok, ^id} =
             Run.run(InlineConverges.tree(),
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

  test "an ambiguous reviewer transport loss reaches the writer outcome-unknown boundary" do
    id = run_id()
    detail = %{"message" => "Codex app-server transport was lost"}

    assert {:error, {:run_crashed, {:codex_turn_outcome_unknown, ^detail}}} =
             Run.run(SequentialReviewerConverges.tree(),
               run_id: id,
               provider: {AmbiguousRefineProvider, ambiguous_at: [0, 1, 0]}
             )

    attempt = %Workflow.IdempotencyKey{run_id: id, node_path: [0, 1, 0], iteration: 0, attempt: 0}
    assert %Status{state: :failed, failure: %{reason: {:outcome_unknown, ^attempt}}} = Status.of(id)
    refute Enum.any?(events(id), &(&1.type == :refine_role_failed))

    assert {:error, {:outcome_unknown, %{address: [0, 1, 0], iteration: 0, attempt: 0}}} =
             Run.run(SequentialReviewerConverges.tree(),
               run_id: id,
               provider: {AmbiguousRefineProvider, ambiguous_at: [0, 1, 0]}
             )
  end

  test "cold-read and repair gates journal descriptors, role effects, and structured result" do
    id = run_id()

    assert {:ok, ^id} =
             Run.run(GateColdRepairEmitResult.tree(),
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

    started_event = Enum.find(events(id), &(&1.type == :refine_started))
    started = started_event.payload
    assert started.gates.cold_read.reviewer.agent.address == [0, 3]
    assert started.gates.cold_read.reviewer.name == :cold
    assert started.gates.repair.agent.address == [0, 4]
    assert started.gates.repair.predicate == {:path_non_empty, "/coldRead/openFindings"}

    assert %{cold_read: %{descriptor: %{address: [0, 3]}}, repair: %{descriptor: %{address: [0, 4]}}} =
             Workflow.Event.payload_map(started_event).gates

    refute Map.has_key?(Workflow.Event.payload_map(started_event).gates, :halt)

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
    assert completed.cold_read.repair == :completed

    assert completed.cold_read.open_findings == [
             %OpenFinding{
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
    Application.put_env(:codex_loops, :refine_reviewer_timeout, 200)

    try do
      timeout_id = run_id()

      assert {:ok, ^timeout_id} =
               Run.run(GateColdRepairEmitResult.tree(),
                 run_id: timeout_id,
                 provider: {ColdReadLaneFailureProvider, failure: :timeout, sink: self()}
               )

      timeout_failure =
        timeout_id
        |> events()
        |> Enum.find(&(&1.type == :refine_role_failed and &1.payload.role == :cold_read))
        |> then(& &1.payload)

      assert timeout_failure.role == :cold_read
      assert timeout_failure.role_address == [0, 3]
      assert timeout_failure.reason == {:cold_read_timeout, 200}
      assert Status.of(timeout_id).state == :completed

      killed_id = run_id()

      assert {:ok, ^killed_id} =
               Run.run(GateColdRepairEmitResult.tree(),
                 run_id: killed_id,
                 provider: {ColdReadLaneFailureProvider, failure: :killed, sink: self()}
               )

      killed_failure =
        killed_id
        |> events()
        |> Enum.find(&(&1.type == :refine_role_failed and &1.payload.role == :cold_read))
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

  test "an ambiguous cold-read transport loss reaches the writer outcome-unknown boundary" do
    id = run_id()
    detail = %{"message" => "Codex app-server transport was lost"}

    assert {:error, {:run_crashed, {:codex_turn_outcome_unknown, ^detail}}} =
             Run.run(GateColdRepairEmitResult.tree(),
               run_id: id,
               provider: {AmbiguousRefineProvider, ambiguous_at: [0, 3]}
             )

    attempt = %Workflow.IdempotencyKey{run_id: id, node_path: [0, 3], iteration: 0, attempt: 0}
    assert %Status{state: :failed, failure: %{reason: {:outcome_unknown, ^attempt}}} = Status.of(id)

    refute Enum.any?(events(id), fn
             %{type: :refine_role_failed, payload: %{role: :cold_read}} -> true
             _event -> false
           end)

    assert {:error, {:outcome_unknown, %{address: [0, 3], iteration: 0, attempt: 0}}} =
             Run.run(GateColdRepairEmitResult.tree(),
               run_id: id,
               provider: {AmbiguousRefineProvider, ambiguous_at: [0, 3]}
             )
  end

  test "repair gate replay turns exhausted rejected attempts into one role failure" do
    id = run_id()
    tree = GateRepairReplayExhausted.tree()
    node = hd(tree.nodes)

    open_findings = [
      open_finding!(%{
        reviewer: :spec,
        reviewer_index: 0,
        id: "base-gap",
        issue: "Base review found a gap.",
        fix: "Repair the base gap."
      })
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
      Workflow.Event.refine_round_decision(
        node,
        0,
        round_decision!(%{
          consensus: false,
          approval_count: 1,
          total: 2,
          reviewer_decisions: [
            reviewer_decision!(%{
              reviewer: :spec,
              outcome: :rejected,
              adapter: :findings_v1,
              reviewer_index: 0
            }),
            reviewer_decision!(%{
              reviewer: :runtime,
              outcome: :clear,
              adapter: :findings_v1,
              reviewer_index: 1
            })
          ],
          artifact: "draft-v1",
          open_findings: open_findings,
          role_failures: [],
          failed_reviewers: [],
          report_snippets: []
        })
      ),
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
             Run.run(GateRepairReplayExhausted.tree(),
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
             Run.run(GateHaltAcceptCurrent.tree(),
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

  test "resume rejects edited gate predicates before replaying journaled decisions" do
    id = run_id()
    tree = GateReplayColdTrue.tree()
    node = hd(tree.nodes)

    key = fn address ->
      %Workflow.IdempotencyKey{run_id: id, node_path: address, iteration: 0, attempt: 0}
    end

    open_findings = [
      open_finding!(%{
        reviewer: :spec,
        reviewer_index: 0,
        id: "base-gap",
        issue: "Base review found a gap.",
        fix: "Repair the base gap."
      })
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
      Workflow.Event.refine_round_decision(
        node,
        0,
        round_decision!(%{
          consensus: false,
          approval_count: 1,
          total: 2,
          reviewer_decisions: [
            reviewer_decision!(%{
              reviewer: :spec,
              outcome: :rejected,
              adapter: :findings_v1,
              reviewer_index: 0
            }),
            reviewer_decision!(%{
              reviewer: :runtime,
              outcome: :clear,
              adapter: :findings_v1,
              reviewer_index: 1
            })
          ],
          artifact: "draft-v1",
          open_findings: open_findings,
          role_failures: [],
          failed_reviewers: [],
          report_snippets: []
        })
      ),
      Workflow.Event.refine_gate_evaluated(node, :cold_read, {:path_non_empty, "/openFindings"},
        result: true,
        input_round: 0,
        input_refs: []
      )
    ]

    Enum.reduce(seeded, 0, fn event, seq ->
      assert {:ok, %{seq: ^seq}} = Journal.append_next(id, event)
      seq + 1
    end)

    before_events = events(id)

    assert {:error, {:tree_fingerprint_mismatch, _recorded, _current}} =
             Run.run(GateReplayColdFalseEdit.tree(),
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

    assert events(id) == before_events
    refute_received {:agent_called, _, _}
  end

  test "non-convergence fail mode journals terminal refine_non_converged and resumes same error" do
    id = run_id()

    assert {:error, {:did_not_converge, [0], :max_rounds}} =
             Run.run(NonConvergesFail.tree(),
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
             Run.run(NonConvergesFail.tree(),
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
             Run.run(NonConvergesAccept.tree(),
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
             %OpenFinding{
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
             Run.run(AcceptCurrentEmit.tree(),
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
      Workflow.Event.run_started(InlineConverges.tree()),
      Workflow.Event.refine_started(hd(InlineConverges.tree().nodes)),
      Workflow.Event.agent_committed(
        %Workflow.Node.Agent{address: [0, 0], prompt: "Draft."},
        0,
        key.([0, 0]),
        "draft-v1",
        %Usage{}
      ),
      Workflow.Event.refine_round_started(
        hd(InlineConverges.tree().nodes),
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
      Workflow.Event.refine_round_decision(
        hd(InlineConverges.tree().nodes),
        0,
        round_decision!(%{
          consensus: true,
          approval_count: 2,
          total: 2,
          reviewer_decisions: [
            reviewer_decision!(%{reviewer: :spec, reviewer_index: 0, outcome: :clear}),
            reviewer_decision!(%{reviewer: :runtime, reviewer_index: 1, outcome: :clear})
          ],
          artifact: "draft-v1",
          open_findings: []
        })
      ),
      Workflow.Event.refine_completed(
        hd(InlineConverges.tree().nodes),
        terminal_projection!(%{
          converged: true,
          final_round: 0,
          rounds: 1,
          artifact: "draft-v1",
          open_findings: []
        })
      )
    ]

    Enum.reduce(events, 0, fn event, seq ->
      assert {:ok, %{seq: ^seq}} = Journal.append_next(id, event)
      seq + 1
    end)

    assert {:ok, ^id} =
             Run.run(InlineConverges.tree(),
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
