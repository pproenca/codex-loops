defmodule Workflow.Run.Writer do
  @moduledoc """
  The single live writer for one run. It walks the inert tree, invokes the provider
  for agent nodes, drives dynamic loops, and commits ordered events to the journal.

  It owns a genuine serialised resource — the per-run write lease and the `seq`
  cursor — which is exactly what a process is for. The lease is the registry name:
  `start_link/1` registers `{:via, Registry, {Registry, run_id}}`, so a second
  writer for the same `run_id` fails with `{:already_started, pid}`. The registry
  monitors this process, releasing the lease on death.

  `start_link` returns as soon as the lease is held; the writer then idles until it
  receives `:begin`. Deferring the work to a message (rather than a
  `handle_continue`) lets the caller establish its `Process.monitor` before any
  effect runs, so a mid-turn crash is observed with its real exit reason rather
  than a `:noproc` race. On `:begin` the writer executes, reports its result to the
  caller, and stops `:normal`. Crashes propagate to the caller via its monitor —
  let it crash.

  ## Execution context

  A small context threads through the walk: the `seq` cursor, the pending `return`
  value, the current loop `iteration` (0 at top level, the real per-iteration key
  component inside a loop), the enclosing loop's `seen_by` dedup field list, and the
  most recent agent result (`last_result`) that a `collect` reduces. It carries no
  authoritative state — every decision that matters is journaled and re-derivable by
  folding the log.
  """
  use GenServer, restart: :temporary

  alias Workflow.{
    Journal,
    Event,
    Idempotency,
    IdempotencyKey,
    Schema,
    Status,
    Ledger,
    Accumulator,
    BoundValue,
    Predicate,
    PubSub,
    RenderText,
    Template
  }

  alias Workflow.Node.{
    Phase,
    Log,
    Agent,
    Emit,
    Return,
    Parallel,
    Pipeline,
    Collect,
    WhileBudget,
    UntilDry,
    Verify,
    Refine,
    Judge,
    Synthesize,
    FanOut,
    BudgetSlices
  }

  @refine_artifact_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "properties" => %{"artifact" => %{"type" => "string"}},
    "required" => ["artifact"]
  }

  @refine_review_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "properties" => %{
      "approved" => %{"type" => "boolean"},
      "findings" => %{
        "type" => "array",
        "items" => %{
          "type" => "object",
          "additionalProperties" => false,
          "properties" => %{
            "id" => %{"type" => "string"},
            "blocking" => %{"type" => "boolean"},
            "issue" => %{"type" => "string"},
            "fix" => %{"type" => "string"}
          },
          "required" => ["id", "blocking", "issue", "fix"]
        }
      }
    },
    "required" => ["approved", "findings"]
  }

  # The agent turn is capped by `retries` on-thread, so a bounded fan-out timeout is
  # unnecessary; concurrent branches simply wait on their (mock or real) provider.
  @fanout_timeout :infinity
  @default_refine_reviewer_timeout 30_000

  def start_link(opts) do
    run_id = Keyword.fetch!(opts, :run_id)
    GenServer.start_link(__MODULE__, Map.new(opts), name: via(run_id))
  end

  @doc "The registry name that is this run's write lease."
  def via(run_id), do: {:via, Registry, {Workflow.Run.Registry, run_id}}

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_info(:begin, state) do
    result = execute(state)
    send(state.parent, {:run_finished, state.run_id, result})
    {:stop, :normal, state}
  end

  defp execute(%{run_id: run_id, tree: tree, provider: provider} = state) do
    prior = Journal.fold(run_id)

    # Resume is a pure fold. If the journal already folds to a terminal state, that
    # state is reused verbatim: no fresh `run_started` is appended (which would
    # un-terminate the read model) and no settled turn is re-run.
    case Status.fold(prior, run_id) do
      %Status{state: :completed} ->
        {:ok, run_id}

      %Status{state: :failed, failure: failure} ->
        failed_run_result(failure)

      %Status{} ->
        run_tree(
          run_id,
          tree,
          provider,
          prior,
          Map.get(state, :budget),
          Map.get(state, :script_path)
        )
    end
  end

  defp failed_run_result(%{reason: {:invalid_refine_input, address, reason}}),
    do: {:error, {:invalid_refine_input, address, reason}}

  defp failed_run_result(%{reason: {:did_not_converge, address, reason}}),
    do: {:error, {:did_not_converge, address, reason}}

  defp failed_run_result(failure),
    do: {:error, {:malformed_output, failure.address, failure.reason}}

  defp run_tree(run_id, tree, provider, prior, budget, script_path) do
    seq = Journal.last_seq(run_id) + 1

    # A fresh run gets its start marker (carrying the budget target and the source
    # path); a resume already carries one, so appending another would falsely
    # re-mark the folded run as `:running` and re-declare a target the ledger
    # already folded.
    seq =
      if prior == [],
        do: commit(run_id, seq, Event.run_started(tree, budget, script_path)),
        else: seq

    ctx = %{seq: seq, return: nil, last_result: nil, iteration: 0, seen_by: []}

    case run_nodes(tree.nodes, run_id, provider, prior, ctx) do
      {:cont, ctx} ->
        _seq = commit(run_id, ctx.seq, Event.run_completed(ctx.return))
        {:ok, run_id}

      # A node failed closed: its terminal `agent_failed` is already journaled.
      {:halt, _ctx, reason} ->
        {:error, reason}
    end
  end

  # Walk a node list, threading the context and short-circuiting on the first halt.
  defp run_nodes(nodes, run_id, provider, prior, ctx) do
    Enum.reduce_while(nodes, {:cont, ctx}, fn node, {:cont, ctx} ->
      case run_node(node, run_id, provider, prior, ctx) do
        {:cont, ctx} -> {:cont, {:cont, ctx}}
        {:halt, ctx, reason} -> {:halt, {:halt, ctx, reason}}
      end
    end)
  end

  defp run_node(%Phase{} = node, run_id, _provider, prior, ctx),
    do: {:cont, %{ctx | seq: commit_marker(run_id, ctx.seq, prior, Event.phase_entered(node))}}

  defp run_node(%Log{} = node, run_id, _provider, prior, ctx),
    do: {:cont, %{ctx | seq: commit_marker(run_id, ctx.seq, prior, Event.log_emitted(node))}}

  defp run_node(%Return{} = node, _run_id, _provider, _prior, ctx),
    do: {:cont, %{ctx | return: node.value}}

  defp run_node(%Emit{} = node, run_id, _provider, _prior, ctx) do
    rendered =
      case RenderText.of(run_id, Template.to_parts(node.template, node.bindings)) do
        {:ok, value} ->
          value

        {:error, reason} ->
          raise ArgumentError, "unable to render terminal template: #{inspect(reason)}"
      end

    {:cont, %{ctx | return: rendered}}
  end

  # The sequential agent path commits each paid attempt *incrementally* — a rejection
  # lands in the journal before the next paid call runs — so a crash mid-retry
  # durably preserves the already-paid attempts and resume never re-pays them. The
  # committed/replayed result becomes `last_result`, which a following `collect` in
  # the same iteration harvests.
  defp run_node(%Agent{} = node, run_id, provider, prior, ctx) do
    iteration = ctx.iteration

    case resolve_agent_turn(node, prior, iteration) do
      # Exactly-once: a settled turn is replayed from the journal, never re-run.
      {:committed, result, _usage} ->
        {:cont, %{ctx | last_result: result}}

      {:failed, reason} ->
        {:halt, ctx, {:malformed_output, node.address, reason}}

      {:exhausted, attempts, reason} ->
        seq = commit(run_id, ctx.seq, Event.agent_failed(node, iteration, attempts, reason))
        {:halt, %{ctx | seq: seq}, {:malformed_output, node.address, reason}}

      # Mid-flight resume: pick the retry loop back up at the first un-journaled
      # attempt rather than re-calling the provider for already-ledgered rejections.
      {:resume, next} ->
        commit_attempt(materialize_agent(node, run_id), run_id, provider, ctx, iteration, next)

      :none ->
        commit_attempt(materialize_agent(node, run_id), run_id, provider, ctx, iteration, 0)
    end
  end

  # A declared reduction. On resume, an iteration whose `accumulate` already landed
  # is replayed (skipped) so the accumulator is never double-counted. Otherwise the
  # iteration's harvest (`last_result`) is deduped against the journal-folded
  # accumulator using the enclosing loop's `seen_by`, and only the new items are
  # journaled — so folding the log rebuilds the accumulator exactly.
  defp run_node(%Collect{} = node, run_id, _provider, prior, ctx) do
    if journaled_accumulate?(prior, node.address, ctx.iteration) do
      {:cont, ctx}
    else
      harvest = List.wrap(ctx.last_result)
      current = Map.get(Accumulator.of(run_id), node.into, [])
      added = Accumulator.new_items(current, harvest, ctx.seen_by)

      event =
        Event.accumulate(node, ctx.iteration, ctx.seen_by, added, length(current) + length(added))

      {:cont, %{ctx | seq: commit(run_id, ctx.seq, event)}}
    end
  end

  # `while_budget`: loop while the ledger's `remaining` exceeds `reserve` (and any
  # `until` predicate stays false). Termination is guaranteed — `remaining` only
  # falls — and bounded by `max_iterations` regardless.
  defp run_node(%WhileBudget{} = node, run_id, provider, prior, ctx),
    do: loop(node, [], run_id, provider, prior, ctx, 0)

  # `until_dry`: loop until `rounds` consecutive iterations add nothing new,
  # deduping by `seen_by`; bounded by `max_iterations`.
  defp run_node(%UntilDry{} = node, run_id, provider, prior, ctx),
    do: loop(node, node.seen_by, run_id, provider, prior, ctx, 0)

  # Barrier fan-out: bracket the concurrent region with started/completed markers,
  # run every branch concurrently under the cap, then commit each branch's journalled
  # events in branch order. Branches build events off-thread and never touch the
  # journal — only this single writer commits.
  defp run_node(%Parallel{} = node, run_id, provider, prior, ctx) do
    seq = commit_marker(run_id, ctx.seq, prior, Event.parallel_started(node))
    cap = node.max_concurrency || max(length(node.branches), 1)

    results =
      run_concurrently(node.branches, cap, fn branch ->
        to_lane_result(build_agent(branch, run_id, provider, prior, ctx.iteration))
      end)

    case commit_lanes(results, run_id, seq) do
      {:ok, seq} ->
        {:cont, %{ctx | seq: commit_marker(run_id, seq, prior, Event.parallel_completed(node))}}

      {:halt, seq, reason} ->
        {:halt, %{ctx | seq: seq}, reason}
    end
  end

  # Per-item fan-out: each lane runs its stages sequentially and independently; lanes
  # run concurrently under the cap with no cross-item barrier.
  defp run_node(%Pipeline{} = node, run_id, provider, prior, ctx) do
    seq = commit_marker(run_id, ctx.seq, prior, Event.pipeline_started(node))
    cap = node.max_concurrency || max(length(node.lanes), 1)

    results =
      run_concurrently(node.lanes, cap, fn lane ->
        run_lane(lane, run_id, provider, prior, ctx.iteration)
      end)

    case commit_lanes(results, run_id, seq) do
      {:ok, seq} ->
        {:cont, %{ctx | seq: commit_marker(run_id, seq, prior, Event.pipeline_completed(node))}}

      {:halt, seq, reason} ->
        {:halt, %{ctx | seq: seq}, reason}
    end
  end

  # Verification panel: run every voter concurrently under the (constant) panel
  # width, commit each vote in voter order, then settle survival by a pure fold of
  # the journaled verdicts against the threshold. A failed vote fails the panel.
  defp run_node(%Verify{} = node, run_id, provider, prior, ctx) do
    seq = commit_marker(run_id, ctx.seq, prior, Event.verify_started(node))
    cap = max(length(node.voters), 1)

    outcomes =
      run_concurrently(node.voters, cap, fn voter ->
        build_agent(voter, run_id, provider, prior, ctx.iteration)
      end)

    case commit_with_results(outcomes, run_id, seq) do
      {:ok, seq, votes} ->
        confirmations = Enum.count(votes, &confirmed?/1)
        total = length(votes)
        survived = survives?(confirmations, total, node.threshold)

        seq =
          commit_marker(
            run_id,
            seq,
            prior,
            Event.verify_settled(node, confirmations, total, survived)
          )

        result = %{survived: survived, confirmations: confirmations, total: total}
        {:cont, %{ctx | seq: seq, last_result: result}}

      {:halt, seq, reason} ->
        {:halt, %{ctx | seq: seq}, reason}
    end
  end

  defp run_node(%Refine{} = node, run_id, provider, prior, ctx) do
    node = materialize_refine_runtime(node)
    seq = commit_marker(run_id, ctx.seq, prior, Event.refine_started(node))
    node = replay_refine_started(node, prior)

    with {:ok, seq, artifact} <-
           run_refine_producer(node, run_id, provider, prior, %{ctx | seq: seq}),
         {:ok, seq, artifact} <-
           run_refine_loop(node, 0, artifact, run_id, provider, prior, seq) do
      {:cont, %{ctx | seq: seq, last_result: artifact}}
    else
      {:failed, seq, reason} -> {:halt, %{ctx | seq: seq}, reason}
    end
  end

  # Judge panel: score every candidate lane concurrently (each lane scores its
  # criteria in order), commit scores in candidate order, then pick a winner by a
  # pure fold of the journaled scores. A failed score fails the panel.
  defp run_node(%Judge{} = node, run_id, provider, prior, ctx) do
    seq = commit_marker(run_id, ctx.seq, prior, Event.judge_started(node))
    cap = max(length(node.scorers), 1)

    outcomes =
      run_concurrently(node.scorers, cap, fn lane ->
        score_lane(lane, run_id, provider, prior, ctx.iteration)
      end)

    case commit_with_results(outcomes, run_id, seq) do
      {:ok, seq, totals} ->
        scores = node.candidates |> Enum.zip(totals) |> Map.new()
        winner = pick_winner(node.pick, scores)
        seq = commit_marker(run_id, seq, prior, Event.judge_settled(node, scores, winner))
        {:cont, %{ctx | seq: seq, last_result: %{winner: winner, scores: scores}}}

      {:halt, seq, reason} ->
        {:halt, %{ctx | seq: seq}, reason}
    end
  end

  # Synthesis is one schemaless, exactly-once agent turn whose effective prompt
  # deterministically embeds the literal inputs; it reuses the ordinary agent path
  # verbatim, so it is journaled, keyed, and resumable with no special case.
  defp run_node(%Synthesize{} = node, run_id, provider, prior, ctx) do
    agent = %Agent{address: node.address, prompt: synthesis_prompt(node), schema: nil, retries: 0}
    run_node(agent, run_id, provider, prior, ctx)
  end

  # Budget-scaled fan-out: decide (and journal) the width once, then run that many
  # branches concurrently under the cap, each a lane over the body re-addressed to
  # `parent ++ [branch, stage]`.
  defp run_node(%FanOut{} = node, run_id, provider, prior, ctx) do
    {width, seq} = decide_width(node, run_id, prior, ctx.seq)
    branches = for i <- 0..(width - 1)//1, do: rebase_body(node.body, node.address ++ [i])
    cap = node.max_concurrency || max(width, 1)

    results =
      run_concurrently(branches, cap, fn lane ->
        run_lane(lane, run_id, provider, prior, ctx.iteration)
      end)

    case commit_lanes(results, run_id, seq) do
      {:ok, seq} ->
        {:cont, %{ctx | seq: commit_marker(run_id, seq, prior, Event.fan_out_completed(node))}}

      {:halt, seq, reason} ->
        {:halt, %{ctx | seq: seq}, reason}
    end
  end

  # --- Verify / judge tally (pure folds over each panel's committed results) ---

  defp confirmed?(vote), do: Map.get(vote, "verdict") == true

  defp survives?(confirmations, total, :majority), do: confirmations * 2 > total
  defp survives?(confirmations, total, :unanimous), do: confirmations == total
  defp survives?(confirmations, _total, :any), do: confirmations >= 1
  defp survives?(confirmations, _total, n) when is_integer(n), do: confirmations >= n

  defp replay_refine_started(%Refine{} = node, prior) do
    case journaled_refine_started(prior, node.address) do
      {:ok, payload} -> refine_from_started_payload(node, payload)
      :none -> node
    end
  end

  defp journaled_refine_started(prior, address) do
    case Enum.find(prior, &(&1.type == :refine_started and &1.payload.address == address)) do
      nil -> :none
      event -> {:ok, event.payload}
    end
  end

  defp refine_from_started_payload(%Refine{} = node, payload) do
    %{
      node
      | input: refine_input_from_descriptor(payload.input),
        reviewers: Enum.map(payload.reviewers, &reviewer_from_descriptor/1),
        reviser: agent_from_descriptor(payload.reviser, @refine_artifact_schema),
        until: payload.until,
        max_rounds: payload.max_rounds,
        on_non_convergence: payload.on_non_convergence,
        max_concurrency: payload.max_concurrency,
        reviewer_timeout_ms: payload[:reviewer_timeout_ms] || refine_reviewer_timeout()
    }
  end

  defp materialize_refine_runtime(%Refine{} = node) do
    %{node | reviewer_timeout_ms: node.reviewer_timeout_ms || refine_reviewer_timeout()}
  end

  defp refine_input_from_descriptor(%{kind: :producer} = descriptor),
    do: {:producer, agent_from_descriptor(descriptor, @refine_artifact_schema)}

  defp refine_input_from_descriptor(%{kind: :binding, name: name, ref: ref}),
    do: {:binding, name, ref}

  defp reviewer_from_descriptor(%{index: index, name: name} = descriptor) do
    %{
      index: index,
      name: name,
      prompt: descriptor.prompt,
      agent: agent_from_descriptor(descriptor, @refine_review_schema)
    }
  end

  defp agent_from_descriptor(descriptor, schema) do
    %Agent{
      address: descriptor.address,
      prompt: descriptor.prompt,
      retries: descriptor.retries,
      label: descriptor.label,
      schema: schema
    }
  end

  defp run_refine_producer(%Refine{input: {:producer, producer}}, run_id, provider, prior, ctx) do
    case commit_role_agent(producer, run_id, provider, prior, ctx, 0, &normalize_artifact/1) do
      {:cont, ctx, artifact} ->
        {:ok, ctx.seq, artifact}

      {:halt, ctx, reason} ->
        {:failed, ctx.seq, reason}
    end
  end

  defp run_refine_producer(
         %Refine{input: {:binding, name, ref}} = node,
         run_id,
         _provider,
         _prior,
         ctx
       ) do
    case bound_artifact(run_id, ref) do
      {:ok, artifact} ->
        {:ok, ctx.seq, artifact}

      {:error, reason} ->
        input = %{kind: :binding, name: name, ref: ref}
        seq = commit(run_id, ctx.seq, Event.refine_input_invalid(node, input, reason))
        {:failed, seq, {:invalid_refine_input, node.address, reason}}
    end
  end

  defp bound_artifact(_run_id, {:map, _address}), do: {:error, :unsupported_map_binding}

  defp bound_artifact(run_id, ref) do
    with {:ok, value} <- BoundValue.of(run_id, ref) do
      normalize_bound_artifact(value)
    else
      {:error, {:unbound, _ref}} -> {:error, :unbound_binding}
      {:error, _reason} -> {:error, :artifact_value_unsupported}
    end
  end

  defp normalize_bound_artifact(value) when is_binary(value) do
    if String.valid?(value), do: {:ok, value}, else: {:error, :artifact_invalid_utf8}
  end

  defp normalize_bound_artifact(%{"artifact" => artifact} = value)
       when map_size(value) == 1 and is_binary(artifact) do
    if String.valid?(artifact), do: {:ok, artifact}, else: {:error, :artifact_invalid_utf8}
  end

  defp normalize_bound_artifact(%{"artifact" => value}) when not is_binary(value),
    do: {:error, :artifact_not_binary}

  defp normalize_bound_artifact(value) when is_map(value),
    do: {:error, :artifact_object_unexpected_shape}

  defp normalize_bound_artifact(_value), do: {:error, :artifact_value_unsupported}

  defp run_refine_round(%Refine{} = node, round, artifact, run_id, provider, prior, seq) do
    seq =
      commit_round_marker(
        run_id,
        seq,
        prior,
        Event.refine_round_started(node, round, artifact)
      )

    case journaled_refine_decision(prior, node.address, round) do
      {:ok, decision} ->
        {:ok, seq, decision}

      :none ->
        run_refine_reviewers(node, round, artifact, run_id, provider, prior, seq)
    end
  end

  defp run_refine_reviewers(%Refine{} = node, round, artifact, run_id, provider, prior, seq) do
    cap = node.max_concurrency || max(length(node.reviewers), 1)
    timeout = node.reviewer_timeout_ms || refine_reviewer_timeout()

    outcomes =
      run_refine_reviewers_concurrently(node.reviewers, cap, timeout, round, fn %{
                                                                                  agent: agent,
                                                                                  prompt:
                                                                                    base_prompt
                                                                                } ->
        agent = %{agent | prompt: reviewer_prompt(base_prompt, round, artifact)}
        build_role_agent(agent, run_id, provider, prior, round, &normalize_review/1)
      end)

    case commit_with_results(outcomes, run_id, seq) do
      {:ok, seq, reviews} ->
        decision = refine_decision(node, round, artifact, reviews)
        seq = commit(run_id, seq, Event.refine_round_decision(node, round, decision))
        {:ok, seq, decision}

      {:halt, seq, reason} ->
        {:failed, seq, reason}
    end
  end

  defp run_refine_loop(%Refine{} = node, round, artifact, run_id, provider, prior, seq) do
    with {:ok, seq, decision} <-
           run_refine_round(node, round, artifact, run_id, provider, prior, seq) do
      cond do
        decision.consensus ->
          seq =
            commit_refine_completed(
              run_id,
              seq,
              prior,
              Event.refine_completed(node, %{
                converged: true,
                final_round: round,
                rounds: round + 1,
                artifact: artifact,
                open_findings: []
              })
            )

          {:ok, seq, artifact}

        round == node.max_rounds - 1 and node.on_non_convergence == :accept_current ->
          seq =
            commit_refine_completed(
              run_id,
              seq,
              prior,
              Event.refine_completed(node, %{
                converged: false,
                final_round: round,
                rounds: round + 1,
                artifact: artifact,
                open_findings: decision.open_findings
              })
            )

          {:ok, seq, artifact}

        round == node.max_rounds - 1 ->
          seq =
            commit_refine_non_converged(
              run_id,
              seq,
              prior,
              Event.refine_non_converged(node, %{
                final_round: round,
                rounds: round + 1,
                artifact: artifact,
                open_findings: decision.open_findings
              })
            )

          {:failed, seq, {:did_not_converge, node.address, :max_rounds}}

        true ->
          case run_refine_reviser(
                 node,
                 round,
                 artifact,
                 decision.open_findings,
                 run_id,
                 provider,
                 prior,
                 seq
               ) do
            {:ok, seq, revised_artifact} ->
              run_refine_loop(node, round + 1, revised_artifact, run_id, provider, prior, seq)

            {:failed, seq, reason} ->
              {:failed, seq, reason}
          end
      end
    end
  end

  defp run_refine_reviser(
         %Refine{} = node,
         round,
         artifact,
         open_findings,
         run_id,
         provider,
         prior,
         seq
       ) do
    reviser = %{
      node.reviser
      | prompt: reviser_prompt(node.reviser.prompt, round, artifact, open_findings)
    }

    case commit_role_agent(
           reviser,
           run_id,
           provider,
           prior,
           %{seq: seq},
           round,
           &normalize_artifact/1
         ) do
      {:cont, ctx, revised_artifact} ->
        {:ok, ctx.seq, revised_artifact}

      {:halt, ctx, reason} ->
        {:failed, ctx.seq, reason}
    end
  end

  defp refine_decision(%Refine{} = node, _round, artifact, reviews) do
    decisions =
      node.reviewers
      |> Enum.zip(reviews)
      |> Enum.map(fn {%{index: index, name: name}, review} ->
        approved = Map.fetch!(review, "approved")
        clear = approved and not Enum.any?(review["findings"], &(&1["blocking"] == true))
        %{reviewer: name, reviewer_index: index, approved: approved, clear: clear}
      end)

    open_findings =
      node.reviewers
      |> Enum.zip(reviews)
      |> Enum.flat_map(fn {%{index: index, name: name}, review} ->
        blocking =
          review["findings"]
          |> Enum.filter(&(&1["blocking"] == true))
          |> Enum.uniq_by(& &1["id"])
          |> Enum.sort_by(& &1["id"], :asc)

        cond do
          blocking != [] ->
            Enum.map(blocking, &open_finding(name, index, &1))

          review["approved"] == false ->
            [
              %{
                reviewer: name,
                reviewer_index: index,
                id: "__codex_loops_no_blocking_finding__",
                issue: "Reviewer did not approve but returned no blocking finding.",
                fix:
                  "Revise the artifact to address this reviewer, or return approved: true with no blocking findings."
              }
            ]

          true ->
            []
        end
      end)

    approval_count = Enum.count(decisions, & &1.clear)

    %{
      consensus: approval_count == length(decisions),
      approval_count: approval_count,
      total: length(decisions),
      reviewer_decisions: decisions,
      artifact: artifact,
      open_findings: open_findings
    }
  end

  defp open_finding(name, index, finding) do
    %{
      reviewer: name,
      reviewer_index: index,
      id: finding["id"],
      issue: finding["issue"],
      fix: finding["fix"]
    }
  end

  defp reviewer_prompt(base, round, artifact) do
    RenderText.render!([], [
      {:text, base},
      {:text, "\n\n--- CODEX LOOPS REFINE REVIEW INPUT ---\n"},
      {:text, "round: #{round}\n"},
      {:text, "artifact-bytes: #{byte_size(artifact)}\n"},
      {:text, "artifact:\n"},
      {:text, artifact},
      {:text, "\n--- END CODEX LOOPS REFINE REVIEW INPUT ---"}
    ])
  end

  defp reviser_prompt(base, round, artifact, open_findings) do
    RenderText.render!([], [
      {:text, base},
      {:text, "\n\n--- CODEX LOOPS REFINE REVISION INPUT ---\n"},
      {:text, "round: #{round}\n"},
      {:text, "current-artifact-bytes: #{byte_size(artifact)}\n"},
      {:text, "current-artifact:\n"},
      {:text, artifact},
      {:text, "\nblocking-finding-count: #{length(open_findings)}\n"},
      {:text, serialize_findings(open_findings)},
      {:text, "--- END CODEX LOOPS REFINE REVISION INPUT ---"}
    ])
  end

  defp serialize_findings(open_findings) do
    open_findings
    |> Enum.with_index(1)
    |> Enum.map_join(fn {finding, index} ->
      [
        "finding #{index}:\n",
        "reviewer: #{finding.reviewer}\n",
        "reviewer-index: #{finding.reviewer_index}\n",
        "id-bytes: #{byte_size(finding.id)}\n",
        "id:\n",
        finding.id,
        "\n",
        "issue-bytes: #{byte_size(finding.issue)}\n",
        "issue:\n",
        finding.issue,
        "\n",
        "fix-bytes: #{byte_size(finding.fix)}\n",
        "fix:\n",
        finding.fix,
        "\n"
      ]
    end)
  end

  defp commit_round_marker(run_id, seq, prior, %Event{type: type, payload: payload} = event)
       when type in [:refine_round_started, :refine_round_decision] do
    if Enum.any?(
         prior,
         &(&1.type == type and &1.payload.address == payload.address and
             &1.payload.round == payload.round)
       ) do
      seq
    else
      commit(run_id, seq, event)
    end
  end

  defp commit_refine_completed(run_id, seq, prior, %Event{payload: %{address: address}} = event) do
    if Enum.any?(prior, &(&1.type == :refine_completed and &1.payload.address == address)) do
      seq
    else
      commit(run_id, seq, event)
    end
  end

  defp commit_refine_non_converged(
         run_id,
         seq,
         prior,
         %Event{payload: %{address: address}} = event
       ) do
    if Enum.any?(prior, &(&1.type == :refine_non_converged and &1.payload.address == address)) do
      seq
    else
      commit(run_id, seq, event)
    end
  end

  defp journaled_refine_decision(prior, address, round) do
    case Enum.find(
           prior,
           &(&1.type == :refine_round_decision and &1.payload.address == address and
               &1.payload.round == round)
         ) do
      nil -> :none
      event -> {:ok, Map.delete(event.payload, :address) |> Map.delete(:round)}
    end
  end

  # A candidate's total is the sum of its per-criterion scores.
  defp score_lane(lane, run_id, provider, prior, iteration) do
    Enum.reduce_while(lane, {:ok, [], 0}, fn agent, {:ok, events, total} ->
      case build_agent(agent, run_id, provider, prior, iteration) do
        {:ok, evs, result} -> {:cont, {:ok, events ++ evs, total + Map.get(result, "score", 0)}}
        {:failed, evs, reason} -> {:halt, {:failed, events ++ evs, reason}}
      end
    end)
    |> case do
      {:ok, events, total} -> {:ok, events, total}
      {:failed, _events, _reason} = failed -> failed
    end
  end

  defp pick_winner(:max_score, scores), do: scores |> Enum.max_by(&elem(&1, 1)) |> elem(0)
  defp pick_winner(:min_score, scores), do: scores |> Enum.min_by(&elem(&1, 1)) |> elem(0)

  # Commit each lane's events in order (like `commit_lanes`) while threading the
  # per-lane result out for the panel to fold. On a failed lane the events still
  # commit; the first failure reason halts the panel.
  defp commit_with_results(outcomes, run_id, seq) do
    {seq, results, failure} =
      Enum.reduce(outcomes, {seq, [], nil}, fn
        {:ok, events, result}, {seq, results, failure} ->
          {commit_all(run_id, seq, events), [result | results], failure}

        {:failed, events, reason}, {seq, results, failure} ->
          {commit_all(run_id, seq, events), results, failure || reason}
      end)

    case failure do
      nil -> {:ok, seq, Enum.reverse(results)}
      reason -> {:halt, seq, reason}
    end
  end

  defp synthesis_prompt(%Synthesize{inputs: inputs, prompt: prompt}),
    do:
      RenderText.render!([], [
        {:text, prompt},
        {:text, "\n\nInputs: "},
        {:literal, inputs}
      ])

  # --- Budget-scaled fan-out width (a journaled runtime decision) ---

  # Decide the width once and journal it; a resume replays the journaled width rather
  # than recomputing `floor(remaining / per)` against a ledger the branches have
  # since spent down.
  defp decide_width(%FanOut{} = node, run_id, prior, seq) do
    case journaled_fan_out_width(prior, node.address) do
      {:ok, width} ->
        {width, seq}

      :none ->
        width = compute_width(node.width, run_id)
        {width, commit(run_id, seq, Event.fan_out_started(node, width))}
    end
  end

  defp compute_width(%BudgetSlices{per: per}, run_id) do
    case Ledger.remaining(Ledger.of(run_id)) do
      :infinity ->
        raise ArgumentError, "budget_slices requires a bounded run (no budget target set)"

      remaining ->
        div(max(remaining, 0), per)
    end
  end

  defp journaled_fan_out_width(prior, address) do
    case Enum.find(prior, fn e -> e.type == :fan_out_started and e.payload.address == address end) do
      nil -> :none
      event -> {:ok, event.payload.width}
    end
  end

  # Re-address a body template lane onto a concrete branch: stage `s` -> `branch ++ [s]`.
  defp rebase_body(body, branch_address) do
    Enum.with_index(body, fn %Agent{} = agent, s -> %{agent | address: branch_address ++ [s]} end)
  end

  # --- Dynamic loop driver ---

  # One tail-recursive pass per prospective iteration. The continue/stop *decision*
  # is journaled and, on resume, replayed from the log rather than recomputed — a
  # fresh recompute would read a ledger/accumulator fold that reflects the whole run,
  # not the historical decision point. A `:continue` runs the body under this
  # iteration's key (its committed turns replay on resume); a `:stop` closes the loop
  # bracket.
  defp loop(node, seen_by, run_id, provider, prior, ctx, iteration) do
    {decision, ctx} = decide(node, run_id, prior, ctx, iteration)

    case decision do
      :stop ->
        {:cont,
         %{
           ctx
           | seq: commit_marker(run_id, ctx.seq, prior, Event.loop_completed(node, iteration))
         }}

      :continue ->
        seq = iteration_marker(run_id, ctx.seq, prior, node, iteration)
        body_ctx = %{ctx | seq: seq, iteration: iteration, seen_by: seen_by, last_result: nil}

        case run_nodes(node.body, run_id, provider, prior, body_ctx) do
          {:cont, body_ctx} ->
            loop(
              node,
              seen_by,
              run_id,
              provider,
              prior,
              %{ctx | seq: body_ctx.seq},
              iteration + 1
            )

          {:halt, body_ctx, reason} ->
            {:halt, %{ctx | seq: body_ctx.seq}, reason}
        end
    end
  end

  # Replay a journaled decision verbatim; only compute (and journal) a fresh one when
  # this iteration has never been decided.
  defp decide(node, run_id, prior, ctx, iteration) do
    case journaled_decision(prior, node.address, iteration) do
      {:ok, decision} ->
        {decision, ctx}

      :none ->
        decision = fresh_decision(node, run_id, iteration)

        {decision,
         %{ctx | seq: commit(run_id, ctx.seq, Event.loop_decision(node, iteration, decision))}}
    end
  end

  defp fresh_decision(%WhileBudget{} = node, run_id, iteration) do
    cond do
      iteration >= node.max_iterations -> :stop
      node.until && Predicate.evaluate(node.until, predicate_context(run_id)) -> :stop
      Ledger.remaining(Ledger.of(run_id)) > node.reserve -> :continue
      true -> :stop
    end
  end

  defp fresh_decision(%UntilDry{} = node, run_id, iteration) do
    cond do
      iteration >= node.max_iterations -> :stop
      dry_streak(run_id, node.address, iteration) >= node.rounds -> :stop
      true -> :continue
    end
  end

  defp predicate_context(run_id) do
    %{accumulators: Accumulator.of(run_id), remaining: Ledger.remaining(Ledger.of(run_id))}
  end

  # Consecutive most-recent iterations (ending at `iteration - 1`) whose `collect`s
  # added nothing — derived purely from the journal, never from re-run agent output.
  defp dry_streak(run_id, loop_address, iteration) do
    added_by_round =
      run_id
      |> Journal.fold()
      |> Enum.filter(
        &(&1.type == :accumulate and List.starts_with?(&1.payload.address, loop_address))
      )
      |> Enum.group_by(& &1.payload.iteration, &length(&1.payload.added))
      |> Map.new(fn {round, counts} -> {round, Enum.sum(counts)} end)

    count_trailing_dry(added_by_round, iteration - 1, 0)
  end

  defp count_trailing_dry(_added_by_round, round, streak) when round < 0, do: streak

  defp count_trailing_dry(added_by_round, round, streak) do
    case Map.get(added_by_round, round, 0) do
      0 -> count_trailing_dry(added_by_round, round - 1, streak + 1)
      _ -> streak
    end
  end

  # --- Bounded, ordered concurrent fan-out (shared by parallel/pipeline) ---

  defp run_concurrently(inputs, cap, fun) do
    inputs
    |> Task.async_stream(fun, max_concurrency: cap, ordered: true, timeout: @fanout_timeout)
    |> Enum.map(fn {:ok, result} -> result end)
  end

  defp run_refine_reviewers_concurrently(reviewers, cap, timeout, iteration, fun) do
    Task.Supervisor.async_stream_nolink(
      Workflow.TaskSupervisor,
      reviewers,
      fn reviewer -> safe_refine_reviewer(reviewer, iteration, fun) end,
      max_concurrency: cap,
      ordered: true,
      timeout: timeout,
      on_timeout: :kill_task
    )
    |> Enum.zip(reviewers)
    |> Enum.map(fn
      {{:ok, result}, _reviewer} ->
        result

      {{:exit, :timeout}, reviewer} ->
        failed_refine_reviewer(reviewer, iteration, {:reviewer_timeout, timeout})

      {{:exit, reason}, reviewer} ->
        failed_refine_reviewer(reviewer, iteration, {:reviewer_crashed, reason})
    end)
  end

  defp safe_refine_reviewer(reviewer, iteration, fun) do
    fun.(reviewer)
  rescue
    exception ->
      failed_refine_reviewer(
        reviewer,
        iteration,
        {:reviewer_crashed, Exception.message(exception)}
      )
  catch
    kind, reason ->
      failed_refine_reviewer(reviewer, iteration, {:reviewer_crashed, {kind, reason}})
  end

  defp failed_refine_reviewer(%{agent: %Agent{} = agent}, iteration, reason) do
    {:failed, [Event.agent_failed(agent, iteration, 1, reason)],
     {:malformed_output, agent.address, reason}}
  end

  defp refine_reviewer_timeout do
    case Application.get_env(
           :codex_loops,
           :refine_reviewer_timeout,
           @default_refine_reviewer_timeout
         ) do
      timeout when is_integer(timeout) and timeout > 0 -> timeout
      _invalid -> @default_refine_reviewer_timeout
    end
  end

  defp run_lane(lane, run_id, provider, prior, iteration) do
    Enum.reduce_while(lane, {:ok, []}, fn agent, {:ok, acc} ->
      case build_agent(agent, run_id, provider, prior, iteration) do
        {:ok, events, _result} -> {:cont, {:ok, acc ++ events}}
        {:failed, events, reason} -> {:halt, {:failed, acc ++ events, reason}}
      end
    end)
  end

  defp to_lane_result({:ok, events, _result}), do: {:ok, events}
  defp to_lane_result({:failed, events, reason}), do: {:failed, events, reason}

  defp commit_lanes(results, run_id, seq) do
    {seq, failure} =
      Enum.reduce(results, {seq, nil}, fn
        {:ok, events}, {seq, failure} ->
          {commit_all(run_id, seq, events), failure}

        {:failed, events, reason}, {seq, failure} ->
          {commit_all(run_id, seq, events), failure || reason}
      end)

    case failure do
      nil -> {:ok, seq}
      reason -> {:halt, seq, reason}
    end
  end

  # --- Sequential agent turn: commits each paid attempt as it happens ---

  defp resolve_agent_turn(%Agent{} = node, prior, iteration) do
    case Idempotency.resolve(prior, node.address, iteration) do
      {:resume, next} when next > node.retries ->
        {:exhausted, next, latest_rejected_reason(prior, node.address, iteration)}

      other ->
        other
    end
  end

  defp latest_rejected_reason(prior, address, iteration) do
    prior
    |> Enum.filter(fn
      %Event{type: :agent_attempt_rejected, payload: %{address: ^address, iteration: ^iteration}} ->
        true

      _event ->
        false
    end)
    |> case do
      [] ->
        :retry_exhausted

      rejected ->
        rejected
        |> Enum.max_by(& &1.payload.attempt)
        |> then(& &1.payload.reason)
    end
  end

  defp commit_attempt(%Agent{schema: nil} = node, run_id, provider, ctx, iteration, attempt) do
    key = key(run_id, node.address, iteration, attempt)
    {activity_sink, finalize_activity} = activity_tracker(run_id, node, iteration, attempt)

    {:ok, result, usage, activity} =
      call_provider(
        provider,
        node.prompt,
        nil,
        key,
        activity_sink
      )

    activity = finalize_activity.(activity)

    seq =
      commit(
        run_id,
        ctx.seq,
        Event.agent_committed(node, iteration, key, result, usage, activity)
      )

    {:cont, %{ctx | seq: seq, last_result: result}}
  end

  defp commit_attempt(%Agent{} = node, run_id, provider, ctx, iteration, attempt) do
    key = key(run_id, node.address, iteration, attempt)
    {activity_sink, finalize_activity} = activity_tracker(run_id, node, iteration, attempt)

    {:ok, output, usage, activity} =
      call_provider(
        provider,
        node.prompt,
        node.schema,
        key,
        activity_sink
      )

    activity = finalize_activity.(activity)

    case Schema.validate(node.schema, output) do
      {:ok, validated} ->
        seq =
          commit(
            run_id,
            ctx.seq,
            Event.agent_committed(node, iteration, key, validated, usage, activity)
          )

        {:cont, %{ctx | seq: seq, last_result: validated}}

      {:error, reason} ->
        seq =
          commit(
            run_id,
            ctx.seq,
            Event.agent_attempt_rejected(
              node,
              iteration,
              attempt,
              output,
              reason,
              usage,
              activity
            )
          )

        if attempt < node.retries do
          commit_attempt(node, run_id, provider, %{ctx | seq: seq}, iteration, attempt + 1)
        else
          seq = commit(run_id, seq, Event.agent_failed(node, iteration, attempt + 1, reason))
          {:halt, %{ctx | seq: seq}, {:malformed_output, node.address, reason}}
        end
    end
  end

  # --- Concurrent agent turn: builds events off-thread for the writer to commit ---

  defp build_agent(%Agent{} = node, run_id, provider, prior, iteration) do
    case resolve_agent_turn(node, prior, iteration) do
      {:committed, result, _usage} ->
        {:ok, [], result}

      {:failed, reason} ->
        {:failed, [], {:malformed_output, node.address, reason}}

      {:exhausted, attempts, reason} ->
        {:failed, [Event.agent_failed(node, iteration, attempts, reason)],
         {:malformed_output, node.address, reason}}

      {:resume, next} ->
        build_attempt(materialize_agent(node, run_id), run_id, provider, iteration, next, [])

      :none ->
        build_attempt(materialize_agent(node, run_id), run_id, provider, iteration, 0, [])
    end
  end

  defp build_role_agent(%Agent{} = node, run_id, provider, prior, iteration, normalizer) do
    case resolve_agent_turn(node, prior, iteration) do
      {:committed, result, _usage} ->
        {:ok, [], result}

      {:failed, reason} ->
        {:failed, [], {:malformed_output, node.address, reason}}

      {:exhausted, attempts, reason} ->
        {:failed, [Event.agent_failed(node, iteration, attempts, reason)],
         {:malformed_output, node.address, reason}}

      {:resume, next} ->
        build_role_attempt(
          materialize_agent(node, run_id),
          run_id,
          provider,
          iteration,
          next,
          [],
          normalizer
        )

      :none ->
        build_role_attempt(
          materialize_agent(node, run_id),
          run_id,
          provider,
          iteration,
          0,
          [],
          normalizer
        )
    end
  end

  defp commit_role_agent(%Agent{} = node, run_id, provider, prior, ctx, iteration, normalizer) do
    case resolve_agent_turn(node, prior, iteration) do
      {:committed, result, _usage} ->
        {:cont, ctx, result}

      {:failed, reason} ->
        {:halt, ctx, {:malformed_output, node.address, reason}}

      {:exhausted, attempts, reason} ->
        seq = commit(run_id, ctx.seq, Event.agent_failed(node, iteration, attempts, reason))
        {:halt, %{ctx | seq: seq}, {:malformed_output, node.address, reason}}

      {:resume, next} ->
        commit_role_attempt(
          materialize_agent(node, run_id),
          run_id,
          provider,
          ctx,
          iteration,
          next,
          normalizer
        )

      :none ->
        commit_role_attempt(
          materialize_agent(node, run_id),
          run_id,
          provider,
          ctx,
          iteration,
          0,
          normalizer
        )
    end
  end

  defp commit_role_attempt(%Agent{} = node, run_id, provider, ctx, iteration, attempt, normalizer) do
    key = key(run_id, node.address, iteration, attempt)
    {activity_sink, finalize_activity} = local_activity_tracker()

    {:ok, output, usage, activity} =
      call_provider(provider, node.prompt, node.schema, key, activity_sink)

    activity = finalize_activity.(activity)

    with {:ok, validated} <- Schema.validate(node.schema, output),
         {:ok, normalized} <- normalizer.(validated) do
      seq =
        commit(
          run_id,
          ctx.seq,
          Event.agent_committed(node, iteration, key, normalized, usage, activity)
        )

      {:cont, %{ctx | seq: seq}, normalized}
    else
      {:error, reason} ->
        seq =
          commit(
            run_id,
            ctx.seq,
            Event.agent_attempt_rejected(
              node,
              iteration,
              attempt,
              output,
              reason,
              usage,
              activity
            )
          )

        if attempt < node.retries do
          commit_role_attempt(
            node,
            run_id,
            provider,
            %{ctx | seq: seq},
            iteration,
            attempt + 1,
            normalizer
          )
        else
          seq = commit(run_id, seq, Event.agent_failed(node, iteration, attempt + 1, reason))
          {:halt, %{ctx | seq: seq}, {:malformed_output, node.address, reason}}
        end
    end
  end

  defp build_role_attempt(%Agent{} = node, run_id, provider, iteration, attempt, acc, normalizer) do
    key = key(run_id, node.address, iteration, attempt)
    {activity_sink, finalize_activity} = local_activity_tracker()

    {:ok, output, usage, activity} =
      call_provider(provider, node.prompt, node.schema, key, activity_sink)

    activity = finalize_activity.(activity)

    with {:ok, validated} <- Schema.validate(node.schema, output),
         {:ok, normalized} <- normalizer.(validated) do
      committed = Event.agent_committed(node, iteration, key, normalized, usage, activity)
      {:ok, Enum.reverse([committed | acc]), normalized}
    else
      {:error, reason} ->
        rejected =
          Event.agent_attempt_rejected(node, iteration, attempt, output, reason, usage, activity)

        if attempt < node.retries do
          build_role_attempt(
            node,
            run_id,
            provider,
            iteration,
            attempt + 1,
            [rejected | acc],
            normalizer
          )
        else
          failed = Event.agent_failed(node, iteration, attempt + 1, reason)

          {:failed, Enum.reverse([failed, rejected | acc]),
           {:malformed_output, node.address, reason}}
        end
    end
  end

  defp normalize_artifact(%{"artifact" => artifact} = output)
       when map_size(output) == 1 and is_binary(artifact) do
    if String.valid?(artifact), do: {:ok, artifact}, else: {:error, :artifact_invalid_utf8}
  end

  defp normalize_artifact(%{"artifact" => value}) when not is_binary(value),
    do: {:error, :artifact_not_binary}

  defp normalize_artifact(_output), do: {:error, :artifact_object_unexpected_shape}

  defp normalize_review(%{"approved" => approved, "findings" => findings} = output)
       when map_size(output) == 2 and is_boolean(approved) and is_list(findings) do
    with {:ok, findings} <- normalize_findings(findings) do
      {:ok, %{"approved" => approved, "findings" => findings}}
    end
  end

  defp normalize_review(_output), do: {:error, :review_object_unexpected_shape}

  defp normalize_findings(findings) do
    findings
    |> Enum.reduce_while({:ok, []}, fn finding, {:ok, acc} ->
      case normalize_finding(finding) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      {:error, _} = err -> err
    end
  end

  defp normalize_finding(
         %{"id" => id, "blocking" => blocking, "issue" => issue, "fix" => fix} = finding
       )
       when map_size(finding) == 4 and is_boolean(blocking) do
    if non_empty_utf8?(id) and non_empty_utf8?(issue) and non_empty_utf8?(fix) do
      {:ok, %{"id" => id, "blocking" => blocking, "issue" => issue, "fix" => fix}}
    else
      {:error, :review_finding_invalid_text}
    end
  end

  defp normalize_finding(_finding), do: {:error, :review_finding_unexpected_shape}

  defp non_empty_utf8?(value), do: is_binary(value) and value != "" and String.valid?(value)

  defp build_attempt(%Agent{schema: nil} = node, run_id, provider, iteration, attempt, _acc) do
    key = key(run_id, node.address, iteration, attempt)
    {activity_sink, finalize_activity} = activity_tracker(run_id, node, iteration, attempt)

    {:ok, result, usage, activity} =
      call_provider(
        provider,
        node.prompt,
        nil,
        key,
        activity_sink
      )

    activity = finalize_activity.(activity)

    {:ok, [Event.agent_committed(node, iteration, key, result, usage, activity)], result}
  end

  defp build_attempt(%Agent{} = node, run_id, provider, iteration, attempt, acc) do
    key = key(run_id, node.address, iteration, attempt)
    {activity_sink, finalize_activity} = activity_tracker(run_id, node, iteration, attempt)

    {:ok, output, usage, activity} =
      call_provider(
        provider,
        node.prompt,
        node.schema,
        key,
        activity_sink
      )

    activity = finalize_activity.(activity)

    case Schema.validate(node.schema, output) do
      {:ok, validated} ->
        committed = Event.agent_committed(node, iteration, key, validated, usage, activity)
        {:ok, Enum.reverse([committed | acc]), validated}

      {:error, reason} ->
        rejected =
          Event.agent_attempt_rejected(node, iteration, attempt, output, reason, usage, activity)

        if attempt < node.retries do
          build_attempt(node, run_id, provider, iteration, attempt + 1, [rejected | acc])
        else
          failed = Event.agent_failed(node, iteration, attempt + 1, reason)

          {:failed, Enum.reverse([failed, rejected | acc]),
           {:malformed_output, node.address, reason}}
        end
    end
  end

  defp key(run_id, address, iteration, attempt),
    do: %IdempotencyKey{
      run_id: run_id,
      node_path: address,
      iteration: iteration,
      attempt: attempt
    }

  defp commit_all(run_id, seq, events),
    do: Enum.reduce(events, seq, fn event, seq -> commit(run_id, seq, event) end)

  defp activity_tracker(run_id, %Agent{} = node, iteration, attempt) do
    counter = :counters.new(1, [])
    table = :ets.new(:workflow_activity, [:ordered_set, :private])

    sink = fn entry ->
      :counters.add(counter, 1, 1)
      activity_index = :counters.get(counter, 1) - 1
      :ets.insert(table, {activity_index, entry})
      event = Event.agent_activity(node, iteration, attempt, activity_index, entry)
      {:ok, event} = Journal.append_next(run_id, event)
      Phoenix.PubSub.broadcast(PubSub, "run:" <> run_id, {:journal_committed, run_id, event})
      :ok
    end

    finalize = fn activity ->
      streamed = :ets.tab2list(table) |> Enum.sort_by(fn {index, _entry} -> index end)
      index_final_activity(List.wrap(activity), streamed)
    end

    {sink, finalize}
  end

  defp local_activity_tracker do
    counter = :counters.new(1, [])
    table = :ets.new(:workflow_activity, [:ordered_set, :private])

    sink = fn entry ->
      :counters.add(counter, 1, 1)
      activity_index = :counters.get(counter, 1) - 1
      :ets.insert(table, {activity_index, entry})
      :ok
    end

    finalize = fn activity ->
      streamed = :ets.tab2list(table) |> Enum.sort_by(fn {index, _entry} -> index end)

      case List.wrap(activity) do
        [] -> Enum.map(streamed, fn {index, entry} -> put_activity_index(entry, index) end)
        activity -> index_final_activity(activity, streamed)
      end
    end

    {sink, finalize}
  end

  defp index_final_activity(activity, streamed) do
    {indexed, _used, _next} =
      Enum.reduce(activity, {[], MapSet.new(), next_activity_index(streamed)}, fn entry,
                                                                                  {acc, used,
                                                                                   next} ->
        case matching_streamed_index(entry, streamed, used) do
          nil ->
            {[Map.put_new(entry, :activity_index, next) | acc], used, next + 1}

          index ->
            {[Map.put_new(entry, :activity_index, index) | acc], MapSet.put(used, index), next}
        end
      end)

    Enum.reverse(indexed)
  end

  defp next_activity_index([]), do: 0
  defp next_activity_index(streamed), do: streamed |> List.last() |> elem(0) |> Kernel.+(1)

  defp matching_streamed_index(entry, streamed, used) do
    Enum.find_value(streamed, fn {index, streamed_entry} ->
      if index not in used and streamed_entry == entry, do: index
    end)
  end

  defp put_activity_index(entry, index) when is_map(entry),
    do: Map.put_new(entry, :activity_index, index)

  defp put_activity_index(entry, _index), do: entry

  defp call_provider({module, opts}, prompt, schema, key, activity_sink),
    do:
      normalize_provider_result(
        module.run_agent(prompt, schema, key, Keyword.put(opts, :activity_sink, activity_sink))
      )

  defp normalize_provider_result({:ok, result, usage}), do: {:ok, result, usage, []}

  defp normalize_provider_result({:ok, result, usage, activity}),
    do: {:ok, result, usage, activity}

  defp materialize_agent(%Agent{} = node, run_id) do
    %{node | prompt: materialize_prompt(node, run_id)}
  end

  defp materialize_prompt(%Agent{prompt: prompt}, _run_id) when is_binary(prompt), do: prompt

  defp materialize_prompt(%Agent{prompt: %Template{} = template, bindings: bindings}, run_id) do
    case RenderText.of(run_id, Template.to_parts(template, bindings)) do
      {:ok, prompt} ->
        prompt

      {:error, reason} ->
        raise ArgumentError, "unable to render agent template prompt: #{inspect(reason)}"
    end
  end

  # --- Journal idempotency for positional (non-paid) events ---

  # A structural marker (phase/log entry, fan-out or loop bracket) is a *positional*
  # event: its identity is `(type, address)`. On a fresh walk it is committed; on
  # resume the tree is re-walked from the top, so any marker already journaled at this
  # address is reused verbatim rather than re-emitted.
  defp commit_marker(run_id, seq, prior, %Event{type: type, payload: %{address: address}} = event) do
    if journaled_marker?(prior, type, address), do: seq, else: commit(run_id, seq, event)
  end

  defp journaled_marker?(prior, type, address) do
    Enum.any?(prior, fn event ->
      event.type == type and Map.get(event.payload, :address) == address
    end)
  end

  # A loop iteration marker is positional per `(address, iteration)`, since the same
  # loop address is re-entered once per iteration.
  defp iteration_marker(run_id, seq, prior, node, iteration) do
    if journaled_iteration?(prior, node.address, iteration),
      do: seq,
      else: commit(run_id, seq, Event.iteration_started(node, iteration))
  end

  defp journaled_iteration?(prior, address, iteration) do
    Enum.any?(prior, fn event ->
      event.type == :iteration_started and event.payload.address == address and
        event.payload.iteration == iteration
    end)
  end

  defp journaled_accumulate?(prior, address, iteration) do
    Enum.any?(prior, fn event ->
      event.type == :accumulate and event.payload.address == address and
        event.payload.iteration == iteration
    end)
  end

  defp journaled_decision(prior, address, iteration) do
    case Enum.find(prior, fn event ->
           event.type == :loop_decision and event.payload.address == address and
             event.payload.iteration == iteration
         end) do
      nil -> :none
      event -> {:ok, event.payload.decision}
    end
  end

  defp commit(run_id, seq, %Event{} = event) do
    {:ok, event} = Journal.append_next(run_id, event)
    # Post-commit broadcast so live read surfaces can subscribe.
    Phoenix.PubSub.broadcast(PubSub, "run:" <> run_id, {:journal_committed, run_id, event})
    max(seq, event.seq + 1)
  end
end
