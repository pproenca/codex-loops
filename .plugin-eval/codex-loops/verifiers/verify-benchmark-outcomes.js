import fs from "node:fs";
import path from "node:path";

const root = process.cwd();
const proofDir = path.join(root, ".codex-loop-eval");

function readText(filePath) {
  try {
    return fs.readFileSync(filePath, "utf8");
  } catch {
    return "";
  }
}

function exists(relativePath) {
  return fs.existsSync(path.join(root, relativePath));
}

function listFiles(relativePath) {
  try {
    return fs.readdirSync(path.join(root, relativePath));
  } catch {
    return [];
  }
}

function normalizeRelativePath(relativePath) {
  return relativePath.split(path.sep).join("/");
}

function listFilesRecursive(relativePath, ignoredDirectories = new Set()) {
  const basePath = path.join(root, relativePath);
  const results = [];

  function walk(currentPath, prefix) {
    let entries = [];
    try {
      entries = fs.readdirSync(currentPath, { withFileTypes: true });
    } catch {
      return;
    }

    for (const entry of entries) {
      const childPath = path.join(currentPath, entry.name);
      const childRelativePath = prefix ? path.join(prefix, entry.name) : entry.name;
      if (entry.isDirectory()) {
        const normalizedChildPath = normalizeRelativePath(childRelativePath);
        if (ignoredDirectories.has(entry.name) || ignoredDirectories.has(normalizedChildPath)) {
          continue;
        }
        walk(childPath, childRelativePath);
      } else {
        results.push(normalizeRelativePath(childRelativePath));
      }
    }
  }

  walk(basePath, "");
  return results;
}

function requireFile(relativePath, failures) {
  if (!exists(relativePath)) {
    failures.push(`Missing required file: ${relativePath}`);
  }
}

function requireText(text, needles, label, failures) {
  const lower = text.toLowerCase();
  for (const needle of needles) {
    if (!lower.includes(needle.toLowerCase())) {
      failures.push(`${label} is missing required evidence: ${needle}`);
    }
  }
}

function normalizeProofLine(line) {
  return line
    .trim()
    .replace(/^>\s*/, "")
    .replace(/^[-*+]\s+/, "")
    .replace(/^\d+\.\s+/, "")
    .replace(/^\$\s*/, "")
    .replace(/^`+|`+$/g, "")
    .trim();
}

function isBenignForbiddenCommandMention(text, occurrenceStart, occurrenceEnd) {
  const beforeOccurrence = text.slice(0, occurrenceStart).trim();
  const afterOccurrence = text.slice(occurrenceEnd).trim();
  const beforePatterns = [
    /\bdid not\s+(?:run|execute|invoke|use|pass)\s*$/,
    /\bdidn't\s+(?:run|execute|invoke|use|pass)\s*$/,
    /\bdo not\s+(?:run|execute|invoke|use|pass)\s*$/,
    /\bdon't\s+(?:run|execute|invoke|use|pass)\s*$/,
    /\bnot\s+(?:run|running|execute|executed|invoke|invoked|use|used|pass|passed|passing)\s*$/,
    /\b(?:should|must|needs? to)\s+avoid\s*$/,
    /\bmust not(?:\s+(?:run|execute|invoke|use|pass))?\s*$/,
    /\bshould not(?:\s+(?:run|execute|invoke|use|pass))?\s*$/,
    /\bwithout\s+(?:running|executing|invoking|using)\s*$/,
    /\bno live execution\s+(?:used|ran|executed|invoked)?\s*$/,
  ];
  const afterPatterns = [
    /^[`'"]*\s*(?:was|were)\s+not\s+used\b/,
    /^[`'"]*\s*(?:was|were)\s+not\s+(?:run|executed|invoked)\b/,
    /^[`'"]*\s*not\s+(?:run|running|execute|executed|invoke|invoked|use|used)\b/,
  ];

  return (
    beforePatterns.some((pattern) => pattern.test(beforeOccurrence)) ||
    afterPatterns.some((pattern) => pattern.test(afterOccurrence))
  );
}

function localClauseAroundOccurrence(line, startIndex, endIndex) {
  const boundaryPattern = /(?:,|;|\.|:|\bbut\b|\bwhile\b|\band\b|\bor\b|&&|\|\|)/gi;
  let clauseStart = 0;
  let clauseEnd = line.length;
  let match;

  while ((match = boundaryPattern.exec(line)) !== null) {
    const boundaryStart = match.index;
    const boundaryEnd = boundaryStart + match[0].length;

    if (boundaryEnd <= startIndex) {
      clauseStart = boundaryEnd;
    } else if (boundaryStart >= endIndex) {
      clauseEnd = boundaryStart;
      break;
    }
  }

  const clause = line.slice(clauseStart, clauseEnd);
  const leadingWhitespace = clause.match(/^\s*/)[0].length;
  return {
    text: clause.trim(),
    occurrenceStart: Math.max(0, startIndex - clauseStart - leadingWhitespace),
    occurrenceEnd: Math.max(0, endIndex - clauseStart - leadingWhitespace),
  };
}

function escapeRegExp(text) {
  return text.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

function flagOccurrencePatterns(text) {
  const escapedText = escapeRegExp(text).replace(/\s+/g, "\\s+");
  return [
    new RegExp(`(?:^|[^\\w-])${escapedText}(?=$|[\\s.,;:!?)}\\]'"'\\\`])`, "i"),
    new RegExp(String.raw`(?:^|[^\\w-])\`${escapedText}\``, "i"),
    new RegExp(`(?:^|[^\\w-])'${escapedText}'`, "i"),
    new RegExp(`(?:^|[^\\w-])"${escapedText}"`, "i"),
  ];
}

function sdkProviderFlagOccurrencePatterns() {
  return [
    ...flagOccurrencePatterns("--provider sdk"),
    /(?:^|[^\w-])--provider=["'`]?sdk["'`]?(?=$|[\s.,;:!?)}\]'"'`])/i,
    /(?:^|[^\w-])--provider\s+["'`]?sdk["'`]?(?=$|[\s.,;:!?)}\]'"'`])/i,
  ];
}

function reportForbiddenOccurrences(line, pattern, label, evidence) {
  const patterns = Array.isArray(pattern) ? pattern : [pattern];
  for (const singlePattern of patterns) {
    const regex = singlePattern.global ? singlePattern : new RegExp(singlePattern.source, `${singlePattern.flags}g`);
    for (const match of line.matchAll(regex)) {
      const startIndex = match.index ?? 0;
      const beforeMatch = line.slice(0, startIndex);
      if (label.startsWith("agent-loops ") && /\bnpx\s+(?:-y\s+|--yes\s+)?$/.test(beforeMatch)) {
        continue;
      }
      const occurrenceClause = localClauseAroundOccurrence(line, startIndex, startIndex + match[0].length);
      if (!isBenignForbiddenCommandMention(occurrenceClause.text, occurrenceClause.occurrenceStart, occurrenceClause.occurrenceEnd)) {
        evidence.push(label);
        return;
      }
    }
  }
}

function forbiddenCommandExecutionEvidence(text) {
  const forbiddenCommands = ["draft", "validate", "test", "workflow", "run", "resume"];
  const commandPatterns = forbiddenCommands.flatMap((command) => [
    { label: `agent-loops ${command}`, pattern: new RegExp(`\\bagent-loops\\s+${command}\\b`) },
    {
      label: `node apps/runtime/dist/cli.js ${command}`,
      pattern: new RegExp(`\\bnode\\s+apps\\/runtime\\/dist\\/cli\\.js\\s+${command}\\b`),
    },
    { label: `npx agent-loops ${command}`, pattern: new RegExp(`\\bnpx\\s+agent-loops\\s+${command}\\b`) },
    { label: `npx -y agent-loops ${command}`, pattern: new RegExp(`\\bnpx\\s+-y\\s+agent-loops\\s+${command}\\b`) },
    { label: `npx --yes agent-loops ${command}`, pattern: new RegExp(`\\bnpx\\s+--yes\\s+agent-loops\\s+${command}\\b`) },
  ]);
  const flagPatterns = [
    { label: "--approved", pattern: flagOccurrencePatterns("--approved") },
    { label: "--provider sdk", pattern: sdkProviderFlagOccurrencePatterns() },
  ];
  const evidence = [];

  for (const rawLine of text.split(/\r?\n/)) {
    const line = normalizeProofLine(rawLine).toLowerCase();
    if (!line) {
      continue;
    }

    for (const { label, pattern } of commandPatterns) {
      reportForbiddenOccurrences(line, pattern, label, evidence);
    }
    for (const { label, pattern } of flagPatterns) {
      reportForbiddenOccurrences(line, pattern, label, evidence);
    }
  }

  return [...new Set(evidence)];
}

function proof(name) {
  const relativePath = `.codex-loop-eval/${name}`;
  return {
    relativePath,
    text: readText(path.join(root, relativePath)),
  };
}

function isLikelyWorkflowScript(relativePath) {
  const text = readText(path.join(root, relativePath));
  const hasWorkflowExecutionEvidence = /\blog\s*\(/.test(text) || /\b(?:return\s+(?:await\s+)?|await\s+)agent\s*\(/.test(text);
  return /^\s*export\s+const\s+meta\b/m.test(text) && /\bphase\s*\(/.test(text) && hasWorkflowExecutionEvidence;
}

function skillSavingWorkflowArtifacts() {
  const artifactPaths = new Set();

  for (const name of listFilesRecursive(".codex-loop-eval/workflows").filter((fileName) => fileName.endsWith(".ts"))) {
    artifactPaths.add(`.codex-loop-eval/workflows/${name}`);
  }

  for (const name of listFilesRecursive(".codex/workflows").filter((fileName) => fileName.endsWith(".ts"))) {
    artifactPaths.add(`.codex/workflows/${name}`);
  }

  for (const name of listFiles(".").filter((fileName) => fileName.endsWith(".ts"))) {
    if (isLikelyWorkflowScript(name)) {
      artifactPaths.add(name);
    }
  }

  for (const name of listFilesRecursive("scripts").filter((fileName) => fileName.endsWith(".ts"))) {
    const relativePath = `scripts/${name}`;
    if (isLikelyWorkflowScript(relativePath)) {
      artifactPaths.add(relativePath);
    }
  }

  return [...artifactPaths];
}

function hasValidSkillFrontmatter(text) {
  const withoutBom = text.replace(/^\uFEFF/, "");
  const match = withoutBom.match(/^---[ \t]*\r?\n([\s\S]*?)\r?\n---[ \t]*(?:\r?\n|$)/);
  if (!match) {
    return false;
  }

  const block = match[1];
  return /^name\s*:\s*\S/m.test(block) && /^description\s*:\s*\S/m.test(block);
}

function verifyDraftAndValidate(failures) {
  const result = proof("draft-and-validate.md");
  requireFile(result.relativePath, failures);
  requireFile(".codex-loop-eval/workflows/benchmark-command-docs-audit.ts", failures);
  requireText(
    result.text,
    [
      "benchmark-command-docs-audit",
      "validate",
      "--args",
      "--json",
      "--no-input",
      "validation.ok",
      "approval",
    ],
    result.relativePath,
    failures,
  );
}

function verifyMockLifecycle(failures) {
  const result = proof("mock-lifecycle-inspection.md");
  requireFile(result.relativePath, failures);
  requireFile(".codex-loop-eval/workflows/benchmark-status-probe.ts", failures);
  requireFile(".agent-loops-runs/benchmark-status-probe.jsonl", failures);

  const workflow = readText(path.join(root, ".codex-loop-eval/workflows/benchmark-status-probe.ts"));
  if (!workflow.trimStart().startsWith("export const meta")) {
    failures.push("benchmark-status-probe workflow must start with `export const meta`.");
  }
  requireText(workflow, ["phase(", "log("], ".codex-loop-eval/workflows/benchmark-status-probe.ts", failures);
  requireText(
    result.text,
    [
      "workflow",
      "--provider mock",
      "--budget small",
      "--json",
      "--no-input",
      "status",
      "inspect",
      "runtimecontract",
      "journal",
    ],
    result.relativePath,
    failures,
  );
}

function verifyUnsupportedHostedBoundary(failures) {
  const result = proof("unsupported-hosted-boundary.md");
  requireFile(result.relativePath, failures);
  requireText(
    result.text,
    [
      "unsupported",
      "hosted",
      "external",
      "workflow ui",
      "skip",
      "retry",
      "local",
      "approval",
    ],
    result.relativePath,
    failures,
  );
  const benchmarkWorkflowFiles = listFiles(".codex-loop-eval/workflows").filter((name) => name.startsWith("benchmark-"));
  if (benchmarkWorkflowFiles.length > 0) {
    failures.push(`Boundary scenario created benchmark workflow files: ${benchmarkWorkflowFiles.join(", ")}`);
  }
  if (exists(".agent-loops-runs")) {
    failures.push("Boundary scenario created `.agent-loops-runs`, but it should not run workflows.");
  }
}

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
  if (!hasValidSkillFrontmatter(skill)) {
    failures.push(`${skillPath} must start with frontmatter containing \`name:\` and \`description:\`.`);
  }
  requireText(skill, ["#", "use this skill", "workflow", "safety gate", "verification"], skillPath, failures);

  for (const evidence of forbiddenCommandExecutionEvidence(result.text)) {
    failures.push(`${result.relativePath} must not run \`${evidence}\` for a skill-saving scenario.`);
  }

  const workflowFiles = skillSavingWorkflowArtifacts();
  if (workflowFiles.length > 0) {
    failures.push(`Skill-saving scenario created workflow files: ${workflowFiles.join(", ")}`);
  }
  if (exists(".agent-loops-runs")) {
    failures.push("Skill-saving scenario created `.agent-loops-runs`, but it should not run workflows.");
  }
}

const knownProofs = [
  "draft-and-validate.md",
  "mock-lifecycle-inspection.md",
  "unsupported-hosted-boundary.md",
  "save-workflow-as-skill.md",
].filter((name) => fs.existsSync(path.join(proofDir, name)));

const failures = [];

if (knownProofs.length !== 1) {
  failures.push(`Expected exactly one scenario proof file, found ${knownProofs.length}: ${knownProofs.join(", ") || "none"}`);
}

if (knownProofs.includes("draft-and-validate.md")) {
  verifyDraftAndValidate(failures);
}
if (knownProofs.includes("mock-lifecycle-inspection.md")) {
  verifyMockLifecycle(failures);
}
if (knownProofs.includes("unsupported-hosted-boundary.md")) {
  verifyUnsupportedHostedBoundary(failures);
}
if (knownProofs.includes("save-workflow-as-skill.md")) {
  verifySaveWorkflowAsSkill(failures);
}

if (failures.length > 0) {
  console.error("Codex Loops benchmark outcome verification failed:");
  for (const failure of failures) {
    console.error(`- ${failure}`);
  }
  process.exit(1);
}

console.log(`Codex Loops benchmark outcome verification passed for ${knownProofs[0]}.`);
