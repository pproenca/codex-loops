import fs from "node:fs";
import path from "node:path";

const root = process.cwd();
const pluginRoot = path.join(root, "plugins/codex-loops");
const failures = [];

function readText(filePath) {
  try {
    return fs.readFileSync(filePath, "utf8");
  } catch {
    return "";
  }
}

function requireFile(relativePath) {
  if (!fs.existsSync(path.join(root, relativePath))) {
    failures.push(`Missing required file: ${relativePath}`);
  }
}

function requireNoLocalPath(relativePath) {
  const text = readText(path.join(root, relativePath));
  if (/\/Users\/[^/\s]+/.test(text)) {
    failures.push(`${relativePath} contains an absolute local /Users path.`);
  }
}

function requireJson(relativePath) {
  const text = readText(path.join(root, relativePath));
  try {
    return JSON.parse(text);
  } catch (error) {
    failures.push(`${relativePath} is not valid JSON: ${error.message}`);
    return {};
  }
}

requireFile("plugins/codex-loops/.codex-plugin/plugin.json");
requireFile("plugins/codex-loops/README.md");
requireFile("plugins/codex-loops/SPEC.md");
requireFile("plugins/codex-loops/skills/codex-loops/SKILL.md");

const pluginJson = requireJson("plugins/codex-loops/.codex-plugin/plugin.json");

if (pluginJson.name !== "codex-loops") {
  failures.push("plugin.json name must be codex-loops.");
}
if (pluginJson.skills !== "./skills/") {
  failures.push("plugin.json skills must point at ./skills/.");
}
if (!pluginJson.interface?.privacyPolicyURL || !pluginJson.interface?.termsOfServiceURL) {
  failures.push("plugin.json must expose privacyPolicyURL and termsOfServiceURL.");
}

const skillFiles = fs.existsSync(path.join(pluginRoot, "skills"))
  ? fs.readdirSync(path.join(pluginRoot, "skills"), { recursive: true }).filter((name) => name.endsWith("SKILL.md"))
  : [];
if (skillFiles.length !== 1) {
  failures.push(`Expected exactly one plugin skill, found ${skillFiles.length}.`);
}

for (const relativePath of [
  ".plugin-eval/codex-loops/benchmark.json",
  "apps/runtime/DESIGN.md",
  "plugins/codex-loops/SPEC.md",
]) {
  requireNoLocalPath(relativePath);
}

if (failures.length > 0) {
  console.error("Codex Loops plugin structure verification failed:");
  for (const failure of failures) {
    console.error(`- ${failure}`);
  }
  process.exit(1);
}

console.log("Codex Loops plugin structure verification passed.");
