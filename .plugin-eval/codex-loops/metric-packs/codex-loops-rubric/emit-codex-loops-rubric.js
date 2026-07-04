import fs from "node:fs";
import path from "node:path";

const [, , targetPathArg, targetKindArg] = process.argv;

const targetPath = path.resolve(targetPathArg || process.env.PLUGIN_EVAL_TARGET || ".");
const targetKind = targetKindArg || process.env.PLUGIN_EVAL_TARGET_KIND || "unknown";

function readText(filePath) {
  try {
    return fs.readFileSync(filePath, "utf8");
  } catch {
    return "";
  }
}

function exists(filePath) {
  return fs.existsSync(filePath);
}

function findRepoRoot(startPath) {
  let current = path.resolve(startPath);
  while (current !== path.dirname(current)) {
    if (exists(path.join(current, "package.json")) && exists(path.join(current, "apps/runtime"))) {
      return current;
    }
    current = path.dirname(current);
  }
  return path.resolve(startPath);
}

function relative(repoRoot, filePath) {
  return path.relative(repoRoot, filePath).replaceAll(path.sep, "/");
}

function extractGeneratedCommandBlock(text) {
  const match = text.match(/<!-- gen:commands -->\s*```bash\n([\s\S]*?)\n```\s*<!-- \/gen:commands -->/);
  return match ? match[1].trim() : "";
}

function containsAll(text, needles) {
  return needles.filter((needle) => text.includes(needle));
}

function checkFromMissing({ id, category, message, evidence, remediation, required, present, failWhenMissing = true }) {
  const missing = required.filter((item) => !present.includes(item));
  if (missing.length === 0) {
    return {
      id,
      category,
      severity: "info",
      status: "pass",
      message,
      evidence,
      remediation: [],
    };
  }

  return {
    id,
    category,
    severity: failWhenMissing ? "error" : "warning",
    status: failWhenMissing ? "fail" : "warn",
    message,
    evidence: [...evidence, `Missing: ${missing.join(", ")}`],
    remediation,
  };
}

const repoRoot = findRepoRoot(targetPath);
const pluginJsonPath = path.join(targetPath, ".codex-plugin/plugin.json");
const pluginReadmePath = path.join(targetPath, "README.md");
const pluginSpecPath = path.join(targetPath, "SPEC.md");
const skillPath = path.join(targetPath, "skills/codex-loops/SKILL.md");
const runtimeReadmePath = path.join(repoRoot, "apps/runtime/README.md");

const pluginJson = JSON.parse(readText(pluginJsonPath) || "{}");
const pluginReadme = readText(pluginReadmePath);
const pluginSpec = readText(pluginSpecPath);
const skill = readText(skillPath);
const runtimeReadme = readText(runtimeReadmePath);
const combinedPluginText = [pluginReadme, pluginSpec, skill, JSON.stringify(pluginJson)].join("\n");

const commandDocs = [
  { label: "runtime README", path: runtimeReadmePath, block: extractGeneratedCommandBlock(runtimeReadme) },
  { label: "plugin README", path: pluginReadmePath, block: extractGeneratedCommandBlock(pluginReadme) },
  { label: "plugin SPEC", path: pluginSpecPath, block: extractGeneratedCommandBlock(pluginSpec) },
  { label: "skill", path: skillPath, block: extractGeneratedCommandBlock(skill) },
];
const baselineCommandBlock = commandDocs[0]?.block || "";
const commandBlockMismatches = commandDocs.filter((doc) => !doc.block || doc.block !== baselineCommandBlock);

const requiredCommands = [
  "agent-loops draft",
  "agent-loops validate",
  "agent-loops test",
  "agent-loops workflow",
  "agent-loops run",
  "agent-loops resume",
  "agent-loops inspect",
  "agent-loops status",
  "agent-loops list",
  "agent-loops serve",
  "agent-loops help",
];
const presentCommands = containsAll(baselineCommandBlock, requiredCommands);

const testingGateSignals = [
  "validate",
  "test --provider mock",
  "before live SDK execution",
  "--approved",
  "bounded args",
  "intended write scope",
];
const presentTestingGateSignals = containsAll(combinedPluginText, testingGateSignals);

const lifecycleSignals = [
  "journal",
  "status",
  "inspect",
  "resume",
  "runtimeContract",
  "latest.json",
  "structured-output fail-closed",
];
const presentLifecycleSignals = containsAll(combinedPluginText, lifecycleSignals);

const boundarySignals = [
  "Hosted workflow services",
  "external workflow UIs",
  "per-agent skip/retry controls",
  "local-only",
  "Do not start a UI server implicitly",
  "caller approval",
];
const presentBoundarySignals = containsAll(combinedPluginText, boundarySignals);

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

const checks = [
  {
    id: "codex-loops-plugin-target-kind",
    category: "codex-loops-rubric",
    severity: targetKind === "plugin" ? "info" : "error",
    status: targetKind === "plugin" ? "pass" : "fail",
    message: "Codex Loops rubric is being run against a plugin target.",
    evidence: [`targetKind=${targetKind}`, relative(repoRoot, targetPath)],
    remediation: targetKind === "plugin" ? [] : ["Run this metric pack against plugins/codex-loops."],
  },
  {
    id: "codex-loops-command-block-parity",
    category: "codex-loops-rubric",
    severity: commandBlockMismatches.length === 0 ? "info" : "error",
    status: commandBlockMismatches.length === 0 ? "pass" : "fail",
    message: "Generated command blocks stay synchronized across runtime docs, plugin docs, spec, and skill.",
    evidence:
      commandBlockMismatches.length === 0
        ? commandDocs.map((doc) => `${doc.label}: ${relative(repoRoot, doc.path)}`)
        : commandBlockMismatches.map((doc) => `Mismatch or missing block: ${doc.label} (${relative(repoRoot, doc.path)})`),
    remediation: commandBlockMismatches.length === 0 ? [] : ["Run `node apps/runtime/scripts/gen-help.mjs` and commit the generated docs."],
  },
  checkFromMissing({
    id: "codex-loops-command-surface-complete",
    category: "codex-loops-rubric",
    message: "The public command surface includes the expected Codex Loops lifecycle commands.",
    evidence: [`Present commands: ${presentCommands.join(", ")}`],
    remediation: ["Update the generated command block or the runtime command table so all lifecycle commands are represented."],
    required: requiredCommands,
    present: presentCommands,
  }),
  checkFromMissing({
    id: "codex-loops-testing-gate-contract",
    category: "codex-loops-rubric",
    message: "The plugin documents the pre-live validation/mock-test gate and approval posture.",
    evidence: [`Present testing gate signals: ${presentTestingGateSignals.join(", ")}`],
    remediation: ["Document validation or mock testing before live execution, bounded args, write scope, and approval requirements."],
    required: testingGateSignals,
    present: presentTestingGateSignals,
  }),
  checkFromMissing({
    id: "codex-loops-local-lifecycle-contract",
    category: "codex-loops-rubric",
    message: "The plugin documents the local journal-backed lifecycle and runtime contract.",
    evidence: [`Present lifecycle signals: ${presentLifecycleSignals.join(", ")}`],
    remediation: ["Document journal-backed status, inspect, resume, latest-run pointer behavior, and runtimeContract fields."],
    required: lifecycleSignals,
    present: presentLifecycleSignals,
  }),
  checkFromMissing({
    id: "codex-loops-boundary-and-ui-contract",
    category: "codex-loops-rubric",
    message: "The plugin clearly distinguishes unsupported hosted workflow surfaces from supported local status UI behavior.",
    evidence: [`Present boundary signals: ${presentBoundarySignals.join(", ")}`],
    remediation: ["Document unsupported hosted workflow services, external workflow UIs, per-agent skip/retry controls, local-only behavior, UI startup gating, and caller-owned approval."],
    required: boundarySignals,
    present: presentBoundarySignals,
  }),
  checkFromMissing({
    id: "codex-loops-artifact-selection-contract",
    category: "codex-loops-rubric",
    message: "The plugin distinguishes executable workflow scripts from reusable Codex skills before writing artifacts.",
    evidence: [`Present artifact-selection signals: ${presentArtifactSelectionSignals.join(", ")}`],
    remediation: ["Document script-vs-skill routing, the ambiguous artifact question, and the rule that skill-saving requests do not call `agent-loops draft`."],
    required: artifactSelectionSignals,
    present: presentArtifactSelectionSignals,
  }),
];

const passCount = checks.filter((check) => check.status === "pass").length;
const contractScore = Math.round((passCount / checks.length) * 100);

const metrics = [
  {
    id: "codex-loops-rubric-contract-score",
    category: "codex-loops-rubric",
    value: contractScore,
    unit: "points",
    band: contractScore === 100 ? "good" : contractScore >= 80 ? "moderate" : "weak",
  },
  {
    id: "codex-loops-command-doc-count",
    category: "codex-loops-rubric",
    value: commandDocs.filter((doc) => doc.block).length,
    unit: "docs",
    band: commandBlockMismatches.length === 0 ? "good" : "weak",
  },
  {
    id: "codex-loops-required-command-count",
    category: "codex-loops-rubric",
    value: presentCommands.length,
    unit: "commands",
    band: presentCommands.length === requiredCommands.length ? "good" : "weak",
  },
  {
    id: "codex-loops-testing-gate-signal-count",
    category: "codex-loops-rubric",
    value: presentTestingGateSignals.length,
    unit: "signals",
    band: presentTestingGateSignals.length === testingGateSignals.length ? "good" : "moderate",
  },
  {
    id: "codex-loops-lifecycle-signal-count",
    category: "codex-loops-rubric",
    value: presentLifecycleSignals.length,
    unit: "signals",
    band: presentLifecycleSignals.length === lifecycleSignals.length ? "good" : "moderate",
  },
  {
    id: "codex-loops-boundary-signal-count",
    category: "codex-loops-rubric",
    value: presentBoundarySignals.length,
    unit: "signals",
    band: presentBoundarySignals.length === boundarySignals.length ? "good" : "moderate",
  },
  {
    id: "codex-loops-artifact-selection-signal-count",
    category: "codex-loops-rubric",
    value: presentArtifactSelectionSignals.length,
    unit: "signals",
    band: presentArtifactSelectionSignals.length === artifactSelectionSignals.length ? "good" : "moderate",
  },
  {
    id: "codex-loops-skill-line-count",
    category: "codex-loops-rubric",
    value: skill.split(/\r?\n/).length,
    unit: "lines",
    band: skill.split(/\r?\n/).length <= 250 ? "good" : "moderate",
  },
];

const artifacts = [
  {
    id: "codex-loops-rubric-inputs",
    type: "metric-pack-inputs",
    label: "Codex Loops rubric inputs",
    description: "Files inspected by the Codex Loops custom metric pack.",
    data: {
      files: [pluginJsonPath, pluginReadmePath, pluginSpecPath, skillPath, runtimeReadmePath].map((filePath) =>
        relative(repoRoot, filePath),
      ),
    },
  },
];

console.log(JSON.stringify({ checks, metrics, artifacts }, null, 2));
