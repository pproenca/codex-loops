# Artifact-Aware Workflow Skill Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the Codex Loops plugin route user intent between executable workflow scripts, reusable Codex skills, or both before writing files.

**Architecture:** Keep the runtime package script-focused and put artifact selection in plugin guidance, docs, and evals. Extend the custom benchmark verifier and metric pack so the new "save as skill" route is measured and cannot silently regress into `agent-loops draft`.

**Tech Stack:** Markdown plugin docs, Codex skill frontmatter, Node.js verifier scripts/tests, plugin-eval benchmark JSON, pnpm workspace checks.

---

## File Structure

- Modify `plugins/codex-loops/skills/codex-loops/SKILL.md`: add artifact routing guidance before script authoring, and update the trigger description so reusable skills are in scope.
- Modify `plugins/codex-loops/SPEC.md`: document the artifact-aware public behavior and add acceptance checks.
- Modify `plugins/codex-loops/README.md`: explain that the plugin can create a reusable skill instead of a workflow script.
- Modify `docs/workflow-authoring.md`: clarify the script-vs-skill distinction for users reading workflow authoring docs.
- Modify `.plugin-eval/codex-loops/benchmark.json`: add a benchmark scenario for "save this workflow as a skill".
- Modify `.plugin-eval/codex-loops/verifiers/verify-benchmark-outcomes.js`: add proof checks for the new skill-saving scenario.
- Modify `.plugin-eval/codex-loops/verifiers/verify-benchmark-outcomes.test.js`: add tests for accepted and rejected skill-saving proofs.
- Modify `.plugin-eval/codex-loops/metric-packs/codex-loops-rubric/emit-codex-loops-rubric.js`: score artifact-selection guidance in static plugin text.

## Task 1: Add Failing Verifier Tests For Skill-Saving Proofs

**Files:**
- Modify: `.plugin-eval/codex-loops/verifiers/verify-benchmark-outcomes.test.js`
- Test: `.plugin-eval/codex-loops/verifiers/verify-benchmark-outcomes.test.js`

- [ ] **Step 1: Add acceptance and rejection tests**

Append these tests to `.plugin-eval/codex-loops/verifiers/verify-benchmark-outcomes.test.js`:

```js
test("accepts skill-saving proof without workflow script artifacts", () => {
  withFixture(
    "save-workflow-as-skill",
    (root) => {
      writeFile(
        root,
        ".codex-loop-eval/save-workflow-as-skill.md",
        [
          "artifact: reusable Codex skill",
          "skill path: .codex-loop-eval/skills/stale-command-blocks/SKILL.md",
          "frontmatter checked",
          "draft command was not used",
          "no live execution was requested",
        ].join("\n"),
      );
      writeFile(
        root,
        ".codex-loop-eval/skills/stale-command-blocks/SKILL.md",
        [
          "---",
          "name: stale-command-blocks",
          "description: Use when checking generated Codex Loops command blocks for drift.",
          "---",
          "",
          "# Stale Command Blocks",
          "",
          "Use this skill to inspect generated command block parity and report verification commands.",
          "",
          "## Workflow",
          "",
          "1. Scout the relevant docs and generated command block source.",
          "2. Compare command blocks without mutating files.",
          "3. Report exact drift and verification commands.",
        ].join("\n"),
      );
    },
    (result) => {
      assert.equal(result.status, 0, result.stderr);
    },
  );
});

test("rejects skill-saving proof that falls back to workflow draft", () => {
  withFixture(
    "save-workflow-as-skill-draft",
    (root) => {
      writeFile(
        root,
        ".codex-loop-eval/save-workflow-as-skill.md",
        "artifact reusable skill but ran agent-loops draft --goal check-command-blocks and created a workflow script",
      );
      writeFile(
        root,
        ".codex-loop-eval/skills/stale-command-blocks/SKILL.md",
        "---\nname: stale-command-blocks\ndescription: Use when checking generated command blocks.\n---\n# Skill\n",
      );
      writeFile(
        root,
        ".codex-loop-eval/workflows/stale-command-blocks.ts",
        'export const meta = { name: "stale-command-blocks", description: "wrong artifact" }\nreturn null\n',
      );
    },
    (result) => {
      assert.notEqual(result.status, 0);
      assert.match(result.stderr, /must not run `agent-loops draft/);
      assert.match(result.stderr, /created workflow files/);
    },
  );
});
```

- [ ] **Step 2: Run the verifier tests and confirm they fail**

Run:

```bash
node --test .plugin-eval/codex-loops/verifiers/verify-benchmark-outcomes.test.js
```

Expected: the new tests fail because `save-workflow-as-skill.md` is not in `knownProofs` and no verifier logic accepts the skill proof yet.

- [ ] **Step 3: Commit the failing tests**

```bash
git add .plugin-eval/codex-loops/verifiers/verify-benchmark-outcomes.test.js
git commit -m "test: cover workflow saved as skill benchmark proof"
```

## Task 2: Implement Skill-Saving Benchmark Verifier

**Files:**
- Modify: `.plugin-eval/codex-loops/verifiers/verify-benchmark-outcomes.js`
- Test: `.plugin-eval/codex-loops/verifiers/verify-benchmark-outcomes.test.js`

- [ ] **Step 1: Add verifier helper**

Insert this function after `verifyUnsupportedHostedBoundary`:

```js
function verifySaveWorkflowAsSkill(failures) {
  const result = proof("save-workflow-as-skill.md");
  const skillPath = ".codex-loop-eval/skills/stale-command-blocks/SKILL.md";
  requireFile(result.relativePath, failures);
  requireFile(skillPath, failures);

  const skill = readText(path.join(root, skillPath));
  requireText(
    result.text,
    [
      "reusable codex skill",
      "skill path",
      "frontmatter",
      "draft command was not used",
      "no live execution",
    ],
    result.relativePath,
    failures,
  );
  requireText(
    skill,
    [
      "---",
      "name:",
      "description:",
      "#",
      "use this skill",
      "workflow",
      "verification",
    ],
    skillPath,
    failures,
  );

  const forbiddenCommandNeedles = [
    "agent-loops draft ",
    "agent-loops draft --",
    "node apps/runtime/dist/cli.js draft",
    "agent-loops workflow",
    "--approved",
    "--provider sdk",
  ];
  for (const needle of forbiddenCommandNeedles) {
    if (result.text.toLowerCase().includes(needle.toLowerCase())) {
      failures.push(`${result.relativePath} must not run \`${needle.trim()}\` for a skill-saving scenario.`);
    }
  }

  const workflowFiles = listFiles(".codex-loop-eval/workflows").filter((name) => name.endsWith(".ts"));
  if (workflowFiles.length > 0) {
    failures.push(`Skill-saving scenario created workflow files: ${workflowFiles.join(", ")}`);
  }
  if (exists(".agent-loops-runs")) {
    failures.push("Skill-saving scenario created `.agent-loops-runs`, but it should not run workflows.");
  }
}
```

- [ ] **Step 2: Register the new proof file**

Change the `knownProofs` list to include the new proof:

```js
const knownProofs = [
  "draft-and-validate.md",
  "mock-lifecycle-inspection.md",
  "unsupported-hosted-boundary.md",
  "save-workflow-as-skill.md",
].filter((name) => fs.existsSync(path.join(proofDir, name)));
```

- [ ] **Step 3: Dispatch the new verifier**

Add this block after the hosted-boundary dispatch:

```js
if (knownProofs.includes("save-workflow-as-skill.md")) {
  verifySaveWorkflowAsSkill(failures);
}
```

- [ ] **Step 4: Run the verifier tests and confirm they pass**

Run:

```bash
node --test .plugin-eval/codex-loops/verifiers/verify-benchmark-outcomes.test.js
```

Expected: all verifier tests pass.

- [ ] **Step 5: Commit verifier implementation**

```bash
git add .plugin-eval/codex-loops/verifiers/verify-benchmark-outcomes.js .plugin-eval/codex-loops/verifiers/verify-benchmark-outcomes.test.js
git commit -m "test: verify skill-saving benchmark artifacts"
```

## Task 3: Add Skill-Saving Benchmark Scenario

**Files:**
- Modify: `.plugin-eval/codex-loops/benchmark.json`
- Test: `.plugin-eval/codex-loops/benchmark.json`

- [ ] **Step 1: Update target jobs**

In `evaluationProtocol.targetJobs`, add this string after the first job:

```json
"Save a reusable workflow-shaped operating procedure as a Codex skill without creating an executable script.",
```

- [ ] **Step 2: Add release-blocking failure**

In `evaluationProtocol.failurePolicy.releaseBlocking`, add:

```json
"A skill-saving request that creates a workflow script or calls `agent-loops draft` instead of creating a `SKILL.md` artifact.",
```

- [ ] **Step 3: Add must-not-happen rule**

In `evaluationProtocol.mustNotHappen`, add:

```json
"Calling `agent-loops draft`, `agent-loops workflow`, or `agent-loops resume` for a request that only asks to save a reusable skill.",
```

- [ ] **Step 4: Add the benchmark scenario**

Insert this object in `scenarios` after `draft-and-validate-workflow`:

```json
{
  "id": "save-workflow-as-skill",
  "title": "Save workflow as reusable skill",
  "purpose": "Measure whether the plugin treats a skill-saving request as a reusable SKILL.md artifact instead of forcing the user through executable workflow script authoring.",
  "userInput": "Use the local Codex plugin \"codex-loops\". A maintainer says: \"Save this workflow as a reusable Codex skill: check whether generated command blocks are stale, report exact drift, and tell the operator which verification command to run.\" In this copied repo, limit scouting to `plugins/codex-loops/skills/codex-loops/SKILL.md`, `plugins/codex-loops/SPEC.md`, `docs/cli.md`, and `node apps/runtime/dist/cli.js help`. Do not run unbounded repo-wide searches, package installs, `agent-loops`, or workflow execution commands. Do not create `.codex-loop-eval/workflows` or `.agent-loops-runs`. Create `.codex-loop-eval/skills/stale-command-blocks/SKILL.md` with valid skill frontmatter, trigger guidance, workflow steps, safety gates, and verification expectations. Write `.codex-loop-eval/save-workflow-as-skill.md` with the selected artifact type, skill path, frontmatter check, and explicit statement that the draft command and live execution were not used.",
  "successChecklist": [
    "The run identifies the requested artifact as a reusable Codex skill, not an executable workflow script.",
    "A skill exists at `.codex-loop-eval/skills/stale-command-blocks/SKILL.md` with valid frontmatter and concrete workflow guidance.",
    "The proof records the skill path, frontmatter check, and no live execution posture.",
    "The run does not call the draft command, create workflow scripts, create journals, or pass `--approved`."
  ]
}
```

- [ ] **Step 5: Validate benchmark JSON**

Run:

```bash
node -e 'JSON.parse(require("fs").readFileSync(".plugin-eval/codex-loops/benchmark.json", "utf8")); console.log("benchmark json ok")'
```

Expected: `benchmark json ok`.

- [ ] **Step 6: Commit benchmark scenario**

```bash
git add .plugin-eval/codex-loops/benchmark.json
git commit -m "test: add skill-saving benchmark scenario"
```

## Task 4: Add Static Metric Coverage For Artifact Selection

**Files:**
- Modify: `.plugin-eval/codex-loops/metric-packs/codex-loops-rubric/emit-codex-loops-rubric.js`
- Test: plugin-eval analyzer command

- [ ] **Step 1: Add artifact-selection signal extraction**

After `presentBoundarySignals`, add:

```js
const artifactSelectionSignals = [
  "executable workflow script",
  "reusable Codex skill",
  "SKILL.md",
  "artifact",
  "both",
  "Do you want this saved as an executable workflow script, a reusable Codex skill, or both?",
  "Do not call `agent-loops draft`",
];
const presentArtifactSelectionSignals = containsAll(combinedPluginText, artifactSelectionSignals);
```

- [ ] **Step 2: Add a rubric check**

Add this check to the `checks` array after `codex-loops-boundary-and-ui-contract`:

```js
  checkFromMissing({
    id: "codex-loops-artifact-selection-contract",
    category: "codex-loops-rubric",
    message: "The plugin distinguishes executable workflow scripts from reusable Codex skills before writing artifacts.",
    evidence: [`Present artifact-selection signals: ${presentArtifactSelectionSignals.join(", ")}`],
    remediation: ["Document script-vs-skill routing, the ambiguous artifact question, and the rule that skill-saving requests do not call `agent-loops draft`."],
    required: artifactSelectionSignals,
    present: presentArtifactSelectionSignals,
  }),
```

- [ ] **Step 3: Add a metric**

Add this metric after `codex-loops-boundary-signal-count`:

```js
  {
    id: "codex-loops-artifact-selection-signal-count",
    category: "codex-loops-rubric",
    value: presentArtifactSelectionSignals.length,
    unit: "signals",
    band: presentArtifactSelectionSignals.length === artifactSelectionSignals.length ? "good" : "moderate",
  },
```

- [ ] **Step 4: Run analyzer and expect a failing artifact-selection check**

Run:

```bash
node /Users/pedroproenca/.codex/plugins/cache/openai-curated-remote/plugin-eval/0.1.2/scripts/plugin-eval.js analyze plugins/codex-loops --metric-pack .plugin-eval/codex-loops/metric-packs/codex-loops-rubric/manifest.json --format markdown
```

Expected: the new `codex-loops-artifact-selection-contract` check fails or warns until plugin guidance is updated.

- [ ] **Step 5: Commit metric-pack check**

```bash
git add .plugin-eval/codex-loops/metric-packs/codex-loops-rubric/emit-codex-loops-rubric.js
git commit -m "test: score artifact selection guidance"
```

## Task 5: Update The Codex Loops Skill Guidance

**Files:**
- Modify: `plugins/codex-loops/skills/codex-loops/SKILL.md`
- Test: plugin-eval analyzer command

- [ ] **Step 1: Update skill frontmatter description**

Replace the description with:

```yaml
description: "Use when the user explicitly asks for Codex Loops, dynamic workflows, fanout, ultracode-style orchestration, lifecycle/status inspection, an executable workflow script, or a reusable Codex skill that captures a workflow-shaped operating procedure."
```

- [ ] **Step 2: Update opening scope paragraph**

Replace the second paragraph with:

```markdown
Codex Loops is the local, path-first workflow runner for Codex dynamic
workflows. Use this skill only when the user explicitly asks for Codex Loops,
fanout/multi-agent orchestration, ultracode-style work, workflow lifecycle
inspection, an executable workflow script, or a reusable Codex skill that
captures a workflow-shaped operating procedure.
```

- [ ] **Step 3: Insert artifact-selection section**

Insert this section immediately before `## When To Use`:

```markdown
## Artifact Selection

Before writing files, classify what the user means by "workflow":

- **Executable workflow script**: use this path when the user asks to run,
  execute, test, resume, inspect, launch, or automate work through Codex Loops.
  Author `.codex/workflows/<name>.ts`, then use the validation or mock-test
  gate before live SDK execution.
- **Reusable Codex skill**: use this path when the user asks to save a workflow
  as a skill, playbook, reusable procedure, or future Codex behavior. Write or
  update a `SKILL.md` in a user-approved skill location using Codex skill
  conventions. Do not call `agent-loops draft`, `agent-loops validate`,
  `agent-loops test`, `agent-loops workflow`, or `agent-loops resume` unless
  the user also asks for an executable script.
- **Both**: when the user explicitly asks for both, write the reusable skill as
  the operating guide and create a tested workflow script only for the
  executable part.
- **Ambiguous**: when the user only says "turn this into a workflow" and the
  intended artifact is unclear, ask: "Do you want this saved as an executable
  workflow script, a reusable Codex skill, or both?"

For skill-saving requests, produce skill frontmatter, trigger guidance, workflow
steps, safety gates, and verification expectations. Treat the skill as reusable
operator guidance, not as a TypeScript workflow script.
```

- [ ] **Step 4: Run analyzer with metric pack**

Run:

```bash
node /Users/pedroproenca/.codex/plugins/cache/openai-curated-remote/plugin-eval/0.1.2/scripts/plugin-eval.js analyze plugins/codex-loops --metric-pack .plugin-eval/codex-loops/metric-packs/codex-loops-rubric/manifest.json --format markdown
```

Expected: `codex-loops-artifact-selection-contract` passes.

- [ ] **Step 5: Commit skill guidance**

```bash
git add plugins/codex-loops/skills/codex-loops/SKILL.md
git commit -m "feat: make Codex Loops skill artifact-aware"
```

## Task 6: Update Plugin Docs And Spec

**Files:**
- Modify: `plugins/codex-loops/SPEC.md`
- Modify: `plugins/codex-loops/README.md`
- Modify: `docs/workflow-authoring.md`
- Test: generated command block parity and plugin structure verifier

- [ ] **Step 1: Add artifact-aware public behavior to plugin spec**

In `plugins/codex-loops/SPEC.md`, add this section after `Programmatic helpers`:

```markdown
Artifact-aware authoring:

- User asks to run, execute, test, resume, inspect, launch, or automate through
  Codex Loops: create an executable workflow script and keep the existing
  validation/mock-test gate.
- User asks to save a workflow as a skill, playbook, reusable procedure, or
  future Codex behavior: create or update a `SKILL.md` in a user-approved skill
  location and do not call `agent-loops draft`.
- User asks for both: create the reusable skill as the operating guide and only
  create a workflow script for the executable portion.
- User says only "workflow" and the artifact is ambiguous: ask whether they want
  an executable workflow script, a reusable Codex skill, or both before writing
  files.
```

- [ ] **Step 2: Add skill-saving acceptance checks to spec**

In `Acceptance Checks`, add these bullets:

```markdown
- Plugin text distinguishes executable workflow scripts from reusable Codex
  skills and includes the artifact clarification question.
- Skill-saving requests are documented as `SKILL.md` authoring requests that do
  not call `agent-loops draft` unless an executable script is also requested.
```

- [ ] **Step 3: Add README explanation**

In `plugins/codex-loops/README.md`, add this section before `The plugin exposes the local journal-backed lifecycle surface:`:

```markdown
## Workflow Scripts Vs Skills

When a request says "workflow", the plugin first determines the artifact:

- executable workflow scripts are saved under `.codex/workflows/<name>.ts` and
  go through validation or mock testing before live execution;
- reusable Codex skills are saved as `SKILL.md` guidance in a user-approved
  skill location and do not require `agent-loops draft`;
- explicit "both" requests can create the skill as the reusable guide and a
  tested workflow script for the executable path.

For ambiguous requests, the plugin asks whether the user wants an executable
workflow script, a reusable Codex skill, or both.
```

- [ ] **Step 4: Add workflow-authoring distinction**

In `docs/workflow-authoring.md`, add this section after `## When To Use A Workflow`:

```markdown
## Choose The Artifact

Use an executable workflow script when the user wants Codex Loops to run,
validate, mock-test, resume, inspect, or launch orchestration through the local
runtime. Use a reusable Codex skill when the user wants to save a workflow as
operator guidance, a playbook, or future Codex behavior.

Skill-saving requests should produce `SKILL.md` frontmatter, trigger guidance,
workflow steps, safety gates, and verification expectations. They should not run
`agent-loops draft` unless the user also asks for an executable script.
```

- [ ] **Step 5: Run command block and plugin structure checks**

Run:

```bash
node apps/runtime/scripts/gen-help.mjs --check
node .plugin-eval/codex-loops/verifiers/verify-plugin-structure.js
```

Expected: both commands exit 0.

- [ ] **Step 6: Commit docs and spec**

```bash
git add plugins/codex-loops/SPEC.md plugins/codex-loops/README.md docs/workflow-authoring.md
git commit -m "docs: document workflow script versus skill artifacts"
```

## Task 7: Run Full Verification And Plugin Eval

**Files:**
- No source edits unless verification exposes an issue.
- Test: repo checks, plugin validation, plugin eval, isolated install sanity.

- [ ] **Step 1: Run verifier tests**

```bash
node --test .plugin-eval/codex-loops/verifiers/verify-benchmark-outcomes.test.js
```

Expected: all tests pass.

- [ ] **Step 2: Validate benchmark JSON**

```bash
node -e 'JSON.parse(require("fs").readFileSync(".plugin-eval/codex-loops/benchmark.json", "utf8")); console.log("benchmark json ok")'
```

Expected: `benchmark json ok`.

- [ ] **Step 3: Validate plugin structure**

```bash
python3 /Users/pedroproenca/.codex/skills/.system/plugin-creator/scripts/validate_plugin.py plugins/codex-loops
node .plugin-eval/codex-loops/verifiers/verify-plugin-structure.js
```

Expected: plugin validation and structure verifier pass.

- [ ] **Step 4: Run plugin eval with metric pack**

```bash
node /Users/pedroproenca/.codex/plugins/cache/openai-curated-remote/plugin-eval/0.1.2/scripts/plugin-eval.js analyze plugins/codex-loops --metric-pack .plugin-eval/codex-loops/metric-packs/codex-loops-rubric/manifest.json --format markdown
```

Expected: grade A, no failing Codex Loops rubric checks, and `codex-loops-artifact-selection-contract` passes.

- [ ] **Step 5: Run full workspace check**

```bash
pnpm run check
```

Expected: status UI typecheck/tests and runtime typecheck/help/boundary/tests pass.

- [ ] **Step 6: Test installability still works from the local marketplace**

```bash
set -e
tmp_home=$(mktemp -d)
mkdir -p "$tmp_home/.codex"
CODEX_HOME="$tmp_home/.codex" codex plugin marketplace add . --json
CODEX_HOME="$tmp_home/.codex" codex plugin add codex-loops@codex-loops --json
rm -rf "$tmp_home"
```

Expected: the install command prints a `pluginId` of `codex-loops@codex-loops`.

- [ ] **Step 7: Confirm no uncommitted verification fixes remain**

Run:

```bash
git status --short
```

Expected: no uncommitted files remain from verification. If verification exposed
a problem, fix the specific failing file, rerun the failing command, and commit
that exact file with a message that names the failure, such as
`fix: keep artifact-aware metric check passing`.

## Task 8: Final Review And Release Commit Shape

**Files:**
- Review: all changed files

- [ ] **Step 1: Inspect final diff**

```bash
git status --short --branch
git log --oneline --decorate --max-count=8
git diff origin/master...HEAD --stat
```

Expected: only planned docs, plugin guidance, benchmark, verifier, and metric-pack files changed after the design commit.

- [ ] **Step 2: Decide whether to preserve the single public release commit**

If the user wants to keep the public repo as one squashed commit, squash the implementation commits and the design commit into the release commit before pushing. If the user wants normal history, push the task commits as-is.

Use this only after confirming the desired history shape:

```bash
git push origin master
```

If the branch was squashed or amended against already-pushed history, use:

```bash
git push --force-with-lease origin master
```

Expected: `origin/master` contains the artifact-aware plugin update and all verification has already passed.
