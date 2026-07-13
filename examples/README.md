# Workflow Examples

These are complete workflows for real engineering work, not minimal syntax
samples. Each file contains one inert, top-level `workflow` declaration and is
loaded by the test suite through the same `Workflow.Script.load_tree/1` gate used
by the scheduler.

Treat the prompts as an executable operating procedure. Read the whole workflow,
adapt any named files or commands to the target repository, and validate it
before spending a live Codex turn.

## Catalog

| Workflow | Problem it solves | Main language surfaces | Workspace effect |
| --- | --- | --- | --- |
| `change_risk_report.exs` | Turns the current diff into an evidence-backed change-risk and mitigation report. | Strict schemas, sequential `let` dataflow, `~P`, render helpers, `emit` | Read-only |
| `release_readiness_panel.exs` | Produces a cross-functional release recommendation from independent build, security, migration, and operations reviews. | Explicit heterogeneous `fanout`, bound lane results, structured aggregation | Read-only |
| `dependency_upgrade_swarm.exs` | Inventories dependency upgrades, scales independent whole-inventory reviews to the inventory size, and consolidates upgrade risk. | `path_count` width, repeated `fanout`, bindings, `emit` | Read-only |
| `budgeted_codebase_onboarding.exs` | Uses the available token budget to sample several independent codebase maps, then creates an onboarding guide. | `budget_slices`, `on_zero`, bounded concurrency, bound fanout | Read-only; requires a finite run budget |
| `flaky_test_hunt.exs` | Repeats targeted flake discovery until the search is dry, broad enough, or near its budget reserve. | Generic `loop`, `any`, `dry`, `count`, `budget_remaining`, `collect` | Runs tests but forbids tracked-file edits |
| `adr_consensus_repair.exs` | Reviews a proposed ADR through three lenses and repairs it until all reviewers approve. | Loop-local explicit fanout, `agree`, body-local `until`, conditional repair | Edits only `docs/adr/PROPOSED.md` |
| `current_diff_refine.exs` | Adversarially reviews and repairs the current change set through primary and fresh cold-read panels. | Chained bound `refine`, reviewer adapters, `emit_result` | May edit the current change plus the smallest necessary tests/docs |
| `incident_triage_workbench.exs` | Runs independent incident investigators, joins their evidence, and produces a response brief. | `parallel` barrier, disjoint filesystem dossiers, top-level dataflow | Writes `.codex/workflow-artifacts/incident-triage/` |
| `reproduction_confidence_pipeline.exs` | Runs repeated, read-only reproduction and confounder audits for one reported defect. | Honest replica `pipeline`, schemas, serial concurrency cap | Runs diagnostic commands but forbids tracked-file edits |
| `storage_architecture_decision.exs` | Creates an architecture decision packet for choosing a storage direction. | `verify`, `judge`, bindable `synthesize`, red-team dataflow | Read-only |

Three workflows write to the workspace: ADR repair is limited to
`docs/adr/PROPOSED.md`, current-diff refinement may also add the smallest tests or
documentation needed to prove the existing change, and incident triage owns only
its four dossier files under `.codex/workflow-artifacts/incident-triage/`. Inspect
their resulting diffs and artifacts. Never point the ADR workflow at an accepted
decision without changing its scope and review contract.

## Validate And Run

From an installed or development bundle, validate through MCP before execution:

```text
workflow_validate script_path=examples/change_risk_report.exs workspace_root=/absolute/path/to/repo
```

For a normal live run against the current workspace:

```text
workflow_start   script_path=examples/change_risk_report.exs workspace_root=/absolute/path/to/repo run_id=change-risk provider=codex
workflow_open_ui run_id=change-risk
```

`change_risk_report.exs` and `current_diff_refine.exs` intentionally consume
staged, unstaged, and untracked work, so pass the reviewed working tree as their
explicit absolute `workspace_root`. When isolation is required, create and
prepare a separate worktree explicitly, then pass that worktree as the root;
Codex Loops continues to use the one installed scheduler service.

The ADR workflow requires `docs/adr/PROPOSED.md`. Incident triage requires one
repository-root `INCIDENT.md` that points to local captured evidence. The
reproduction pipeline requires one repository-root `REPRODUCTION.md` naming
exactly one defect and a safe reproduction command; without that shared contract,
all replicas return a blocked result rather than selecting different targets.

`budgeted_codebase_onboarding.exs` must be started through a surface that supplies
a finite `budget`; its `budget_slices` width cannot resolve for an unbounded run.

The built-in mock provider is an echo provider. It is useful for lifecycle proof,
but it does not fabricate schema-conforming results, so these schema-backed
examples fail closed under `provider=mock`. This is a current product limitation:
the available offline preflight is `workflow_validate` plus the repository's
aggregate example test. Runtime tests that need structured results must use a
schema-aware deterministic provider. Do not treat an echo-mock failure as live
approval; review the prompts, write scopes, and required inputs before choosing
the Codex provider.

## Dataflow Rules Used Here

- Top-level `let` plus `agent(~P"...")` is real sequential dataflow.
- A top-level `fanout bind:` exposes the ordered last result from each lane to a
  later template. Explicit lanes are used when scopes differ.
- Repeated fanout lanes receive the same prompt and no lane index. The dependency
  and onboarding swarms therefore use replicas as independent samples of the
  whole scope; they do not pretend to map one item to one lane.
- `parallel` results are not bindings. The incident workflow gives each branch a
  disjoint dossier file, then reads those files after the barrier.
- Pipeline items are journal labels only. A pipeline stage receives neither the
  item nor the preceding stage result, so the reproduction workflow makes both
  stages self-contained.
- `verify` and `judge` outcomes are journaled observations. They do not halt the
  run and do not flow into later nodes. The storage decision workflow asks
  `synthesize` to assess the literal options independently.
- Loop accumulators support predicates and journal/status inspection; they are
  not top-level template bindings. Discovery examples return a receipt and leave
  their evidence in the durable run record.

These limitations are intentional parts of the current language contract. An
example should expose them plainly rather than imply dataflow that does not
exist.
