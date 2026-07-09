# Codex Exec JSONL And Output-Schema Contract

Wayfinder asset for [Inventory Codex CLI JSONL and output-schema contract](https://github.com/pproenca/codex-loops/issues/83).

## Question

What exact contract should Codex Loops rely on from `codex exec --json`, `--output-schema <FILE>`, and `--output-last-message <FILE>`?

## Sources

- Installed CLI: `codex-cli 0.142.5`, inspected with `codex --version` and `codex exec --help`.
- Live local probe: `codex exec --json --ephemeral --ignore-rules --skip-git-repo-check --sandbox read-only --output-schema <schema> --output-last-message <file>`.
- Official Codex manual fetched by the `openai-docs` skill:
  - `https://developers.openai.com/codex/cli/reference.md`
  - `https://developers.openai.com/codex/noninteractive.md`
- Local OpenAI Codex checkout: `/Users/pedroproenca/Documents/Projects/opensource/codex` at commit `f1affbac5e`.
  - `/Users/pedroproenca/Documents/Projects/opensource/codex/codex-rs/exec/src/cli.rs`
  - `/Users/pedroproenca/Documents/Projects/opensource/codex/codex-rs/exec/src/exec_events.rs`
  - `/Users/pedroproenca/Documents/Projects/opensource/codex/codex-rs/exec/src/event_processor_with_jsonl_output.rs`
  - `/Users/pedroproenca/Documents/Projects/opensource/codex/codex-rs/exec/src/lib.rs`
  - `/Users/pedroproenca/Documents/Projects/opensource/codex/codex-rs/core/src/client_common.rs`
  - `/Users/pedroproenca/Documents/Projects/opensource/codex/codex-rs/core/src/client_common_tests.rs`
  - `/Users/pedroproenca/Documents/Projects/opensource/codex/sdk/typescript/src/thread.ts`
  - `/Users/pedroproenca/Documents/Projects/opensource/codex/sdk/typescript/src/events.ts`
  - `/Users/pedroproenca/Documents/Projects/opensource/codex/sdk/typescript/README.md`

## Decision

Codex Loops should treat `codex exec --json` stdout as the realtime event stream and fold that stream into the final provider result. It should not wait for process exit before delivering progress.

For schema-backed turns, Codex Loops should pass the schema file with `--output-schema <FILE>` and stop embedding JSON Schema text in the prompt. The prompt should still carry task semantics: what to inspect, what evidence to cite, how to interpret fields, and any domain-specific constraints. The schema is the shape contract; the prompt is the work instruction.

Codex Loops should continue to validate the decoded final output locally before journaling `agent_committed`. The CLI asks the model for strict structured output, but Codex Loops owns workflow retry/fail-closed semantics and should keep that deterministic gate.

`--output-last-message <FILE>` is useful as a final-output side channel or diagnostic, but it should not be the primary Codex Loops integration path. In JSON mode, stdout remains JSONL; the final assistant message is also available as an `item.completed` event.

## Event Contract

The top-level JSONL event types in the current source are:

- `thread.started` with `thread_id`.
- `turn.started`.
- `item.started` with `item`.
- `item.updated` with `item`.
- `item.completed` with `item`.
- `turn.completed` with `usage`.
- `turn.failed` with `error`.
- `error` with `message`.

The final assistant-visible answer is the latest completed item whose item type is `agent_message`:

```json
{"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"..."}}
```

For a schema-backed turn, `item.text` is a JSON string. Codex Loops should decode it before local schema validation. In the live probe, the final message file contained the same JSON string:

```json
{"status":"ok","answer":"contract probe"}
```

`turn.completed` carries token usage:

```json
{
  "type": "turn.completed",
  "usage": {
    "input_tokens": 16826,
    "cached_input_tokens": 2432,
    "output_tokens": 83,
    "reasoning_output_tokens": 61
  }
}
```

Failures are signaled by `turn.failed` or stream-level `error`. A failed turn should not be treated as a partial success just because an earlier `agent_message` appeared.

## Streaming Granularity

`codex exec --json` streams events as JSONL while the turn runs. The current event processor emits progress items for command execution, file changes, MCP tool calls, web searches, todo lists, warnings/errors, and turn lifecycle.

The current source does not expose assistant token deltas through `codex exec --json`. In `EventProcessorWithJsonOutput`, started agent messages are suppressed and completed agent messages become `item.completed` events. Therefore Codex Loops can stream the entire CLI event feed in realtime, but should not design around top-level `delta`, `text_delta`, or `content_delta` fields unless a future CLI version documents and emits them.

Practical implication: the realtime UI can show lifecycle, tool activity, plan/todo updates, warnings, reasoning summaries when emitted, and the final assistant message as soon as that event arrives. It should not promise token-by-token assistant text from this contract.

## Output-Schema Contract

The installed CLI exposes:

```text
--output-schema <FILE>
    Path to a JSON Schema file describing the model's final response shape

--json
    Print events to stdout as JSONL

-o, --output-last-message <FILE>
    Specifies file where the last message from the agent should be written
```

The Rust exec implementation reads `--output-schema` as JSON and passes it into `turn/start` as `output_schema`. Core then builds the Responses API request with a text format named `codex_output_schema`, type `json_schema`, `strict: true` for normal exec turns, and the provided schema value.

The TypeScript SDK follows the same pattern: turn options accept a plain `outputSchema`, the SDK writes it to a temporary schema file, passes `--output-schema`, and cleans the temp file up after the run.

## Current Codex Loops Implications

`Workflow.Provider.Codex` already passes schema-backed turns through `--output-schema` and then decodes the final `agent_message` text before the writer validates it. That is the right high-level shape.

What should change later, after the rest of the Wayfinder map resolves:

- Treat the provider as stream-first: parse each JSONL line as it arrives and publish/fold events incrementally.
- Keep the final result as a fold over the same stream, following the SDK pattern where buffered `run()` is built on top of streamed `runStreamed()`.
- Keep local `Workflow.Schema.validate/2` in the writer for deterministic retry/fail-closed semantics.
- Remove framework-authored prompt text that transports or restates the JSON Schema.
- Keep prompt text that describes domain semantics not expressible in JSON Schema.
- Do not rely on non-contract delta fields for assistant output in the current CLI version.
- Consider `--output-last-message` optional. It can help diagnostics or recovery, but the JSONL stream already contains the final assistant message and usage.

## Prompt Text That Can Go Away

When an `agent` call supplies `schema:`, Codex Loops does not need to put the schema itself in the prompt. It also does not need generic boilerplate such as:

```text
Return only JSON matching the schema.
```

That is now owned by `--output-schema`.

Prompt text like this should stay because it is semantic, not structural:

```text
Findings must cite a concrete file and line.
Set verdict to findings when any finding exists, otherwise pass.
Use rule ids from the staff-level-elixir skill where possible.
```

## Open Questions For Later Tickets

- Which event vocabulary should Codex Loops expose for realtime-only progress versus durable journal facts?
- Should raw Codex JSONL events be preserved anywhere, or only normalized into Codex Loops activity/projection events?
- Should `--output-last-message` be added to the provider command for a diagnostic breadcrumb, even if JSONL remains canonical?
- How should Codex Loops version-check or capability-check the CLI before relying on this event shape?
