import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

const verifierPath = path.join(path.dirname(fileURLToPath(import.meta.url)), "verify-benchmark-outcomes.js");

function writeFile(root, relativePath, text) {
  const filePath = path.join(root, relativePath);
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, text, "utf8");
}

function withFixture(name, setup, assertResult) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), `codex-loops-verifier-${name}-`));
  try {
    setup(root);
    const result = spawnSync(process.execPath, [verifierPath], {
      cwd: root,
      encoding: "utf8",
    });
    assertResult(result);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
}

function writeValidSkillSavingProof(root, extraLines = []) {
  writeFile(
    root,
    ".codex-loop-eval/save-workflow-as-skill.md",
    [
      "artifact: reusable Codex skill",
      "skill path: .codex-loop-eval/skills/stale-command-blocks/SKILL.md",
      "frontmatter checked",
      "draft command was not used",
      "no live execution was requested",
      ...extraLines,
    ].join("\n"),
  );
}

function writeValidSkillFile(root) {
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
      "",
      "## Safety Gates",
      "",
      "Do not run workflow execution commands or live SDK paths for skill-saving requests.",
    ].join("\n"),
  );
}

function workflowScriptText(name = "stale-command-blocks") {
  return [
    `export const meta = { name: "${name}", description: "wrong artifact" }`,
    'phase("Probe")',
    'log("ok")',
    "return { ok: true }",
  ].join("\n");
}

test("accepts draft workflow under benchmark-safe workflow directory", () => {
  withFixture(
    "draft-safe-path",
    (root) => {
      writeFile(
        root,
        ".codex-loop-eval/draft-and-validate.md",
        "benchmark-command-docs-audit validate --args --json --no-input validation.ok approval",
      );
      writeFile(
        root,
        ".codex-loop-eval/workflows/benchmark-command-docs-audit.ts",
        'export const meta = { name: "benchmark-command-docs-audit", description: "test" }\nreturn null\n',
      );
    },
    (result) => {
      assert.equal(result.status, 0, result.stderr);
    },
  );
});

test("rejects draft proof without successful validation evidence", () => {
  withFixture(
    "draft-missing-validation-ok",
    (root) => {
      writeFile(
        root,
        ".codex-loop-eval/draft-and-validate.md",
        "benchmark-command-docs-audit validate --args --json --no-input approval",
      );
      writeFile(
        root,
        ".codex-loop-eval/workflows/benchmark-command-docs-audit.ts",
        'export const meta = { name: "benchmark-command-docs-audit", description: "test" }\nreturn null\n',
      );
    },
    (result) => {
      assert.notEqual(result.status, 0);
      assert.match(result.stderr, /validation\.ok/);
    },
  );
});

test("accepts lifecycle workflow under benchmark-safe workflow directory", () => {
  withFixture(
    "lifecycle-safe-path",
    (root) => {
      writeFile(
        root,
        ".codex-loop-eval/mock-lifecycle-inspection.md",
        "node apps/runtime/dist/cli.js workflow .codex-loop-eval/workflows/benchmark-status-probe.ts --provider mock --budget small --json --no-input status inspect runtimeContract journal",
      );
      writeFile(
        root,
        ".codex-loop-eval/workflows/benchmark-status-probe.ts",
        'export const meta = { name: "benchmark-status-probe", description: "test" }\nphase("Probe")\nlog("ok")\nreturn { ok: true }\n',
      );
      writeFile(root, ".agent-loops-runs/benchmark-status-probe.jsonl", "{}\n");
    },
    (result) => {
      assert.equal(result.status, 0, result.stderr);
    },
  );
});

test("rejects lifecycle proof without exact mock workflow flags", () => {
  withFixture(
    "lifecycle-missing-mock-flags",
    (root) => {
      writeFile(root, ".codex-loop-eval/mock-lifecycle-inspection.md", "mock workflow without the SDK provider status inspect runtimeContract journal");
      writeFile(
        root,
        ".codex-loop-eval/workflows/benchmark-status-probe.ts",
        'export const meta = { name: "benchmark-status-probe", description: "test" }\nphase("Probe")\nlog("ok")\nreturn { ok: true }\n',
      );
      writeFile(root, ".agent-loops-runs/benchmark-status-probe.jsonl", "{}\n");
    },
    (result) => {
      assert.notEqual(result.status, 0);
      assert.match(result.stderr, /--provider mock/);
      assert.match(result.stderr, /--budget small/);
    },
  );
});

test("rejects root-level lifecycle workflow fallback", () => {
  withFixture(
    "lifecycle-root-fallback",
    (root) => {
      writeFile(root, ".codex-loop-eval/mock-lifecycle-inspection.md", "provider mock status inspect runtimeContract journal");
      writeFile(
        root,
        "benchmark-status-probe.ts",
        'export const meta = { name: "benchmark-status-probe", description: "test" }\nphase("Probe")\nlog("ok")\nreturn { ok: true }\n',
      );
      writeFile(root, ".agent-loops-runs/benchmark-status-probe.jsonl", "{}\n");
    },
    (result) => {
      assert.notEqual(result.status, 0);
      assert.match(result.stderr, /Missing required file: \.codex-loop-eval\/workflows\/benchmark-status-probe\.ts/);
    },
  );
});

test("accepts hosted boundary proof without workflow execution artifacts", () => {
  withFixture(
    "hosted-boundary",
    (root) => {
      writeFile(
        root,
        ".codex-loop-eval/unsupported-hosted-boundary.md",
        "unsupported hosted service and external workflow UI skip retry local approval",
      );
    },
    (result) => {
      assert.equal(result.status, 0, result.stderr);
    },
  );
});

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
          "",
          "## Safety Gates",
          "",
          "Do not run workflow execution commands or live SDK paths for skill-saving requests.",
        ].join("\n"),
      );
    },
    (result) => {
      assert.equal(result.status, 0, result.stderr);
    },
  );
});

test("accepts skill-saving proof with unrelated workflow-shaped app test fixture", () => {
  withFixture(
    "save-workflow-as-skill-unrelated-app-fixture",
    (root) => {
      writeValidSkillSavingProof(root);
      writeValidSkillFile(root);
      writeFile(
        root,
        "apps/runtime/tests/unrelated-fixture.test.ts",
        [
          'export const meta = { name: "fixture", description: "copied repo fixture" }',
          'phase("Probe")',
          "return agent({ prompt: 'fixture only' })",
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

test("rejects skill-saving proof that runs a bare agent-loops draft command", () => {
  withFixture(
    "save-workflow-as-skill-bare-draft",
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
          "agent-loops draft",
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
          "",
          "## Safety Gates",
          "",
          "Do not run workflow execution commands or live SDK paths for skill-saving requests.",
        ].join("\n"),
      );
    },
    (result) => {
      assert.notEqual(result.status, 0);
      assert.match(result.stderr, /must not run `agent-loops draft`/);
    },
  );
});

test("accepts skill-saving proof with benign forbidden-command prose", () => {
  withFixture(
    "save-workflow-as-skill-benign-prose",
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
          "I did not run agent-loops resume.",
          "The skill should avoid --provider sdk.",
          "No live execution used --approved.",
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
          "",
          "## Safety Gates",
          "",
          "Do not run workflow execution commands or live SDK paths for skill-saving requests.",
        ].join("\n"),
      );
    },
    (result) => {
      assert.equal(result.status, 0, result.stderr);
    },
  );
});

test("rejects skill-saving proof with misplaced skill frontmatter", () => {
  withFixture(
    "save-workflow-as-skill-misplaced-frontmatter",
    (root) => {
      writeValidSkillSavingProof(root);
      writeFile(
        root,
        ".codex-loop-eval/skills/stale-command-blocks/SKILL.md",
        [
          "# Stale Command Blocks",
          "",
          "Use this skill to inspect generated command block parity and report verification commands.",
          "",
          "## Workflow",
          "",
          "1. Scout the relevant docs and generated command block source.",
          "2. Compare command blocks without mutating files.",
          "3. Report exact drift and verification commands.",
          "",
          "---",
          "name: stale-command-blocks",
          "description: Use when checking generated Codex Loops command blocks for drift.",
          "---",
        ].join("\n"),
      );
    },
    (result) => {
      assert.notEqual(result.status, 0);
      assert.match(result.stderr, /frontmatter/);
    },
  );
});

test("rejects skill-saving proof with only a trailing frontmatter delimiter", () => {
  withFixture(
    "save-workflow-as-skill-trailing-frontmatter-delimiter",
    (root) => {
      writeValidSkillSavingProof(root);
      writeFile(
        root,
        ".codex-loop-eval/skills/stale-command-blocks/SKILL.md",
        [
          "# Stale Command Blocks",
          "",
          "name: stale-command-blocks",
          "description: Use when checking generated Codex Loops command blocks for drift.",
          "",
          "Use this skill to inspect generated command block parity and report verification commands.",
          "",
          "## Workflow",
          "",
          "1. Scout the relevant docs and generated command block source.",
          "2. Compare command blocks without mutating files.",
          "3. Report exact drift and verification commands.",
          "---",
        ].join("\n"),
      );
    },
    (result) => {
      assert.notEqual(result.status, 0);
      assert.match(result.stderr, /frontmatter/);
    },
  );
});

test("rejects skill-saving proof without trigger guidance", () => {
  withFixture(
    "save-workflow-as-skill-missing-trigger-guidance",
    (root) => {
      writeValidSkillSavingProof(root);
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
          "Inspect generated command block parity and report verification commands.",
          "",
          "## Workflow",
          "",
          "1. Scout the relevant docs and generated command block source.",
          "2. Compare command blocks without mutating files.",
          "3. Report exact drift and verification commands.",
          "",
          "## Safety Gates",
          "",
          "Do not run workflow execution commands or live SDK paths for skill-saving requests.",
        ].join("\n"),
      );
    },
    (result) => {
      assert.notEqual(result.status, 0);
      assert.match(result.stderr, /use this skill/);
    },
  );
});

test("rejects skill-saving proof without safety gate guidance", () => {
  withFixture(
    "save-workflow-as-skill-missing-safety-gates",
    (root) => {
      writeValidSkillSavingProof(root);
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
      assert.notEqual(result.status, 0);
      assert.match(result.stderr, /safety gate/);
    },
  );
});

test("rejects skill-saving proof when avoid describes why a command ran", () => {
  withFixture(
    "save-workflow-as-skill-ran-command-to-avoid-setup",
    (root) => {
      writeValidSkillSavingProof(root, ["I ran agent-loops draft to avoid manual setup."]);
      writeValidSkillFile(root);
    },
    (result) => {
      assert.notEqual(result.status, 0);
      assert.match(result.stderr, /must not run `agent-loops draft`/);
    },
  );
});

test("rejects skill-saving proof when without describes missing setup after a command ran", () => {
  withFixture(
    "save-workflow-as-skill-ran-command-without-setup",
    (root) => {
      writeValidSkillSavingProof(root, ["I ran agent-loops draft without running manual setup."]);
      writeValidSkillFile(root);
    },
    (result) => {
      assert.notEqual(result.status, 0);
      assert.match(result.stderr, /must not run `agent-loops draft`/);
    },
  );
});

test("rejects skill-saving proof when without describes missing live execution after approved use", () => {
  withFixture(
    "save-workflow-as-skill-used-approved-without-live-execution",
    (root) => {
      writeValidSkillSavingProof(root, ["I used --approved without running live execution."]);
      writeValidSkillFile(root);
    },
    (result) => {
      assert.notEqual(result.status, 0);
      assert.match(result.stderr, /must not run `--approved`/);
    },
  );
});

test("rejects skill-saving proof with mixed same-line command evidence after a comma", () => {
  withFixture(
    "save-workflow-as-skill-mixed-same-line-comma",
    (root) => {
      writeValidSkillSavingProof(root, [
        "I did not run agent-loops resume, agent-loops draft --goal check-command-blocks was executed.",
      ]);
      writeValidSkillFile(root);
    },
    (result) => {
      assert.notEqual(result.status, 0);
      assert.match(result.stderr, /must not run `agent-loops draft`/);
    },
  );
});

test("rejects skill-saving proof with mixed same-line command evidence after while", () => {
  withFixture(
    "save-workflow-as-skill-mixed-same-line-while",
    (root) => {
      writeValidSkillSavingProof(root, [
        "I did not run agent-loops resume while agent-loops draft --goal check-command-blocks was executed.",
      ]);
      writeValidSkillFile(root);
    },
    (result) => {
      assert.notEqual(result.status, 0);
      assert.match(result.stderr, /must not run `agent-loops draft`/);
    },
  );
});

test("rejects skill-saving proof with mixed same-line command evidence after or", () => {
  withFixture(
    "save-workflow-as-skill-mixed-same-line-or",
    (root) => {
      writeValidSkillSavingProof(root, [
        "I did not run agent-loops resume or agent-loops draft --goal check-command-blocks was executed.",
      ]);
      writeValidSkillFile(root);
    },
    (result) => {
      assert.notEqual(result.status, 0);
      assert.match(result.stderr, /must not run `agent-loops draft`/);
    },
  );
});

test("rejects skill-saving proof with mixed same-line command evidence after a period", () => {
  withFixture(
    "save-workflow-as-skill-mixed-same-line-period",
    (root) => {
      writeValidSkillSavingProof(root, [
        "I did not run agent-loops resume. agent-loops draft --goal check-command-blocks was executed.",
      ]);
      writeValidSkillFile(root);
    },
    (result) => {
      assert.notEqual(result.status, 0);
      assert.match(result.stderr, /must not run `agent-loops draft`/);
    },
  );
});

test("rejects skill-saving proof with mixed same-line command evidence after a colon", () => {
  withFixture(
    "save-workflow-as-skill-mixed-same-line-colon",
    (root) => {
      writeValidSkillSavingProof(root, [
        "I did not run agent-loops resume: agent-loops draft --goal check-command-blocks was executed.",
      ]);
      writeValidSkillFile(root);
    },
    (result) => {
      assert.notEqual(result.status, 0);
      assert.match(result.stderr, /must not run `agent-loops draft`/);
    },
  );
});

test("rejects skill-saving proof with shell-wrapper command evidence", () => {
  withFixture(
    "save-workflow-as-skill-shell-wrapper",
    (root) => {
      writeValidSkillSavingProof(root, ["sh -lc 'agent-loops draft --goal check-command-blocks'"]);
      writeValidSkillFile(root);
    },
    (result) => {
      assert.notEqual(result.status, 0);
      assert.match(result.stderr, /must not run `agent-loops draft`/);
    },
  );
});

test("rejects skill-saving proof with backticked approved flag inside execution prose", () => {
  withFixture(
    "save-workflow-as-skill-backticked-approved-flag",
    (root) => {
      writeValidSkillSavingProof(root, ["The command used `--approved`."]);
      writeValidSkillFile(root);
    },
    (result) => {
      assert.notEqual(result.status, 0);
      assert.match(result.stderr, /must not run `--approved`/);
    },
  );
});

test("rejects skill-saving proof with quoted provider flag inside execution prose", () => {
  withFixture(
    "save-workflow-as-skill-quoted-provider-flag",
    (root) => {
      writeValidSkillSavingProof(root, ["The command used '--provider sdk'."]);
      writeValidSkillFile(root);
    },
    (result) => {
      assert.notEqual(result.status, 0);
      assert.match(result.stderr, /must not run `--provider sdk`/);
    },
  );
});

test("accepts skill-saving proof with avoided backticked approved flag", () => {
  withFixture(
    "save-workflow-as-skill-avoided-backticked-approved-flag",
    (root) => {
      writeValidSkillSavingProof(root, ["The skill should avoid `--approved`."]);
      writeValidSkillFile(root);
    },
    (result) => {
      assert.equal(result.status, 0, result.stderr);
    },
  );
});

test("accepts skill-saving proof with post-command benign negation", () => {
  withFixture(
    "save-workflow-as-skill-post-command-negation",
    (root) => {
      writeValidSkillSavingProof(root, ["agent-loops draft was not used."]);
      writeValidSkillFile(root);
    },
    (result) => {
      assert.equal(result.status, 0, result.stderr);
    },
  );
});

test("accepts skill-saving proof with post-flag benign negation", () => {
  withFixture(
    "save-workflow-as-skill-post-flag-negation",
    (root) => {
      writeValidSkillSavingProof(root, ["`--approved` was not used."]);
      writeValidSkillFile(root);
    },
    (result) => {
      assert.equal(result.status, 0, result.stderr);
    },
  );
});

test("accepts skill-saving proof with approved flag pass negation", () => {
  withFixture(
    "save-workflow-as-skill-approved-pass-negation",
    (root) => {
      writeValidSkillSavingProof(root, ["I did not pass --approved."]);
      writeValidSkillFile(root);
    },
    (result) => {
      assert.equal(result.status, 0, result.stderr);
    },
  );
});

test("rejects skill-saving proof with standalone approved flag evidence", () => {
  withFixture(
    "save-workflow-as-skill-approved-flag",
    (root) => {
      writeValidSkillSavingProof(root, ["--approved"]);
      writeValidSkillFile(root);
    },
    (result) => {
      assert.notEqual(result.status, 0);
      assert.match(result.stderr, /must not run `--approved`/);
    },
  );
});

test("rejects skill-saving proof with standalone sdk provider flag evidence", () => {
  withFixture(
    "save-workflow-as-skill-sdk-provider-flag",
    (root) => {
      writeValidSkillSavingProof(root, ["--provider sdk"]);
      writeValidSkillFile(root);
    },
    (result) => {
      assert.notEqual(result.status, 0);
      assert.match(result.stderr, /must not run `--provider sdk`/);
    },
  );
});

test("rejects skill-saving proof with equals sdk provider flag evidence", () => {
  withFixture(
    "save-workflow-as-skill-equals-sdk-provider-flag",
    (root) => {
      writeValidSkillSavingProof(root, ["--provider=sdk"]);
      writeValidSkillFile(root);
    },
    (result) => {
      assert.notEqual(result.status, 0);
      assert.match(result.stderr, /must not run `--provider sdk`/);
    },
  );
});

test("rejects skill-saving proof with double-quoted equals sdk provider flag evidence", () => {
  withFixture(
    "save-workflow-as-skill-double-quoted-equals-sdk-provider-flag",
    (root) => {
      writeValidSkillSavingProof(root, ['The command used --provider="sdk".']);
      writeValidSkillFile(root);
    },
    (result) => {
      assert.notEqual(result.status, 0);
      assert.match(result.stderr, /must not run `--provider sdk`/);
    },
  );
});

test("rejects skill-saving proof with single-quoted equals sdk provider flag evidence", () => {
  withFixture(
    "save-workflow-as-skill-single-quoted-equals-sdk-provider-flag",
    (root) => {
      writeValidSkillSavingProof(root, ["The command used --provider='sdk'."]);
      writeValidSkillFile(root);
    },
    (result) => {
      assert.notEqual(result.status, 0);
      assert.match(result.stderr, /must not run `--provider sdk`/);
    },
  );
});

test("rejects skill-saving proof with backticked equals sdk provider flag evidence", () => {
  withFixture(
    "save-workflow-as-skill-backticked-equals-sdk-provider-flag",
    (root) => {
      writeValidSkillSavingProof(root, ["The command used --provider=`sdk`."]);
      writeValidSkillFile(root);
    },
    (result) => {
      assert.notEqual(result.status, 0);
      assert.match(result.stderr, /must not run `--provider sdk`/);
    },
  );
});

test("rejects skill-saving proof with quoted sdk provider flag evidence", () => {
  withFixture(
    "save-workflow-as-skill-separated-quoted-sdk-provider-flag",
    (root) => {
      writeValidSkillSavingProof(root, ['--provider "sdk"']);
      writeValidSkillFile(root);
    },
    (result) => {
      assert.notEqual(result.status, 0);
      assert.match(result.stderr, /must not run `--provider sdk`/);
    },
  );
});

test("accepts skill-saving proof with benign quoted equals sdk provider prose", () => {
  withFixture(
    "save-workflow-as-skill-benign-quoted-equals-sdk-provider",
    (root) => {
      writeValidSkillSavingProof(root, [
        'The command should avoid --provider="sdk".',
        "--provider='sdk' was not used.",
        "Do not run --provider=`sdk`.",
      ]);
      writeValidSkillFile(root);
    },
    (result) => {
      assert.equal(result.status, 0, result.stderr);
    },
  );
});

test("accepts skill-saving proof with benign equals sdk provider avoidance", () => {
  withFixture(
    "save-workflow-as-skill-benign-equals-sdk-provider",
    (root) => {
      writeValidSkillSavingProof(root, ["The command should avoid --provider=sdk."]);
      writeValidSkillFile(root);
    },
    (result) => {
      assert.equal(result.status, 0, result.stderr);
    },
  );
});

test("accepts skill-saving proof with benign quoted sdk provider negation", () => {
  withFixture(
    "save-workflow-as-skill-benign-quoted-sdk-provider",
    (root) => {
      writeValidSkillSavingProof(root, ['--provider "sdk" was not used.']);
      writeValidSkillFile(root);
    },
    (result) => {
      assert.equal(result.status, 0, result.stderr);
    },
  );
});

test("rejects skill-saving proof with validate test and run command aliases", () => {
  withFixture(
    "save-workflow-as-skill-cli-aliases",
    (root) => {
      writeValidSkillSavingProof(root, [
        "agent-loops validate .codex-loop-eval/workflows/stale-command-blocks.ts --args '{}'",
        "agent-loops test .codex-loop-eval/workflows/stale-command-blocks.ts --args '{}' --provider mock",
        "agent-loops run .codex-loop-eval/workflows/stale-command-blocks.ts --args '{}' --provider mock",
        "node apps/runtime/dist/cli.js run .codex-loop-eval/workflows/stale-command-blocks.ts --args '{}'",
        "npx agent-loops validate .codex-loop-eval/workflows/stale-command-blocks.ts --args '{}'",
        "npx -y agent-loops run .codex-loop-eval/workflows/stale-command-blocks.ts --args '{}'",
        "npx --yes agent-loops test .codex-loop-eval/workflows/stale-command-blocks.ts --args '{}'",
      ]);
      writeValidSkillFile(root);
    },
    (result) => {
      assert.notEqual(result.status, 0);
      assert.match(result.stderr, /must not run `agent-loops validate`/);
      assert.match(result.stderr, /must not run `agent-loops test`/);
      assert.match(result.stderr, /must not run `agent-loops run`/);
      assert.match(result.stderr, /must not run `node apps\/runtime\/dist\/cli\.js run`/);
      assert.match(result.stderr, /must not run `npx agent-loops validate`/);
      assert.match(result.stderr, /must not run `npx -y agent-loops run`/);
      assert.match(result.stderr, /must not run `npx --yes agent-loops test`/);
    },
  );
});

test("rejects skill-saving proof with mixed benign and executed command clauses", () => {
  withFixture(
    "save-workflow-as-skill-mixed-clauses",
    (root) => {
      writeValidSkillSavingProof(root, [
        "I did not run agent-loops resume, but agent-loops draft --goal check-command-blocks was executed.",
      ]);
      writeValidSkillFile(root);
    },
    (result) => {
      assert.notEqual(result.status, 0);
      assert.match(result.stderr, /must not run `agent-loops draft`/);
    },
  );
});

test("rejects skill-saving proof with env-prefixed forbidden command", () => {
  withFixture(
    "save-workflow-as-skill-env-prefixed-command",
    (root) => {
      writeValidSkillSavingProof(root, ["CI=1 agent-loops draft --goal check-command-blocks"]);
      writeValidSkillFile(root);
    },
    (result) => {
      assert.notEqual(result.status, 0);
      assert.match(result.stderr, /must not run `agent-loops draft`/);
    },
  );
});

test("rejects skill-saving proof with npx package CLI command evidence", () => {
  withFixture(
    "save-workflow-as-skill-npx-package-cli",
    (root) => {
      writeValidSkillSavingProof(root, [
        "npx -y agent-loops draft --goal check-command-blocks",
        "npx -y agent-loops workflow .codex-loop-eval/workflows/stale-command-blocks.ts",
        "npx -y agent-loops resume --goal check-command-blocks",
      ]);
      writeValidSkillFile(root);
    },
    (result) => {
      assert.notEqual(result.status, 0);
      assert.match(result.stderr, /must not run `npx -y agent-loops draft`/);
      assert.match(result.stderr, /must not run `npx -y agent-loops workflow`/);
      assert.match(result.stderr, /must not run `npx -y agent-loops resume`/);
    },
  );
});

test("rejects skill-saving proof with alternate npx package CLI command evidence", () => {
  withFixture(
    "save-workflow-as-skill-npx-package-cli-alternates",
    (root) => {
      writeValidSkillSavingProof(root, [
        "npx agent-loops draft --goal check-command-blocks",
        "npx --yes agent-loops draft --goal check-command-blocks",
        "npx agent-loops workflow .codex-loop-eval/workflows/stale-command-blocks.ts",
        "npx --yes agent-loops workflow .codex-loop-eval/workflows/stale-command-blocks.ts",
        "npx agent-loops resume --goal check-command-blocks",
        "npx --yes agent-loops resume --goal check-command-blocks",
      ]);
      writeValidSkillFile(root);
    },
    (result) => {
      assert.notEqual(result.status, 0);
      assert.match(result.stderr, /must not run `npx agent-loops draft`/);
      assert.match(result.stderr, /must not run `npx --yes agent-loops draft`/);
      assert.match(result.stderr, /must not run `npx agent-loops workflow`/);
      assert.match(result.stderr, /must not run `npx --yes agent-loops workflow`/);
      assert.match(result.stderr, /must not run `npx agent-loops resume`/);
      assert.match(result.stderr, /must not run `npx --yes agent-loops resume`/);
    },
  );
});

test("accepts skill-saving proof with benign npx package CLI prose", () => {
  withFixture(
    "save-workflow-as-skill-benign-npx-package-cli",
    (root) => {
      writeValidSkillSavingProof(root, [
        "I did not run npx -y agent-loops draft.",
        "The skill should avoid npx -y agent-loops workflow.",
        "npx -y agent-loops resume was not used.",
      ]);
      writeValidSkillFile(root);
    },
    (result) => {
      assert.equal(result.status, 0, result.stderr);
    },
  );
});

test("rejects skill-saving proof that resumes an agent-loops workflow", () => {
  withFixture(
    "save-workflow-as-skill-resume",
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
          "agent-loops resume --goal check-command-blocks",
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
          "",
          "## Safety Gates",
          "",
          "Do not run workflow execution commands or live SDK paths for skill-saving requests.",
        ].join("\n"),
      );
    },
    (result) => {
      assert.notEqual(result.status, 0);
      assert.match(result.stderr, /must not run `agent-loops resume/);
    },
  );
});

test("rejects skill-saving proof that runs an explicit runtime workflow command", () => {
  withFixture(
    "save-workflow-as-skill-runtime-workflow",
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
          "node apps/runtime/dist/cli.js workflow .codex-loop-eval/workflows/stale-command-blocks.ts --provider mock",
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
          "",
          "## Safety Gates",
          "",
          "Do not run workflow execution commands or live SDK paths for skill-saving requests.",
        ].join("\n"),
      );
    },
    (result) => {
      assert.notEqual(result.status, 0);
      assert.match(result.stderr, /must not run `node apps\/runtime\/dist\/cli\.js workflow/);
    },
  );
});

test("rejects skill-saving proof that creates .codex workflow artifacts", () => {
  withFixture(
    "save-workflow-as-skill-dot-codex-workflow",
    (root) => {
      writeValidSkillSavingProof(root);
      writeValidSkillFile(root);
      writeFile(root, ".codex/workflows/stale-command-blocks.ts", workflowScriptText());
    },
    (result) => {
      assert.notEqual(result.status, 0);
      assert.match(result.stderr, /\.codex\/workflows\/stale-command-blocks\.ts/);
    },
  );
});

test("rejects skill-saving proof that creates root-level workflow-looking artifacts", () => {
  withFixture(
    "save-workflow-as-skill-root-workflow",
    (root) => {
      writeValidSkillSavingProof(root);
      writeValidSkillFile(root);
      writeFile(root, "stale-command-blocks.ts", workflowScriptText());
    },
    (result) => {
      assert.notEqual(result.status, 0);
      assert.match(result.stderr, /stale-command-blocks\.ts/);
    },
  );
});

test("rejects skill-saving proof that creates scripts workflow-looking artifacts", () => {
  withFixture(
    "save-workflow-as-skill-scripts-workflow",
    (root) => {
      writeValidSkillSavingProof(root);
      writeValidSkillFile(root);
      writeFile(root, "scripts/stale-command-blocks.ts", workflowScriptText());
    },
    (result) => {
      assert.notEqual(result.status, 0);
      assert.match(result.stderr, /scripts\/stale-command-blocks\.ts/);
    },
  );
});

test("rejects skill-saving proof that creates scripts workflow artifact with agent execution", () => {
  withFixture(
    "save-workflow-as-skill-scripts-agent-workflow",
    (root) => {
      writeValidSkillSavingProof(root);
      writeValidSkillFile(root);
      writeFile(
        root,
        "scripts/stale-command-blocks.ts",
        [
          'export const meta = { name: "stale-command-blocks", description: "wrong artifact" }',
          'phase("Plan")',
          "return agent({ prompt: 'check command blocks' })",
        ].join("\n"),
      );
    },
    (result) => {
      assert.notEqual(result.status, 0);
      assert.match(result.stderr, /scripts\/stale-command-blocks\.ts/);
    },
  );
});

test("rejects skill-saving proof that creates nested workflow artifacts", () => {
  withFixture(
    "save-workflow-as-skill-nested-workflow",
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
          "",
          "## Safety Gates",
          "",
          "Do not run workflow execution commands or live SDK paths for skill-saving requests.",
        ].join("\n"),
      );
      writeFile(
        root,
        ".codex-loop-eval/workflows/nested/foo.ts",
        workflowScriptText("foo"),
      );
    },
    (result) => {
      assert.notEqual(result.status, 0);
      assert.match(result.stderr, /created workflow files/);
    },
  );
});
