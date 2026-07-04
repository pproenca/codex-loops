import assert from "node:assert/strict"
import { test } from "node:test"

import {
  FIRST_META_ERROR, FORBIDDEN_SOURCE_ERROR, MISSING_HOOK_ERROR, PLAIN_JS_ERROR, PURE_META_ERROR,
  RUNNER_ONLY_HELPER_ERROR, parseWorkflowMeta, validateCompatibleWorkflowScript,
} from "../src/trust/workflow-script.ts"
import type { WorkflowCompatibilityCode, WorkflowCompatibilityFinding, WorkflowCompatibilityResult } from "../src/domain/contracts.ts"

function errorsOf(result: WorkflowCompatibilityResult, code: WorkflowCompatibilityCode): WorkflowCompatibilityFinding[] {
  return result.findings.filter((finding) => finding.code === code && finding.severity === "error")
}

function assertLocated(finding: WorkflowCompatibilityFinding | undefined): asserts finding is WorkflowCompatibilityFinding {
  assert.ok(finding, "expected a finding")
  assert.ok(Number.isInteger(finding.line) && finding.line >= 1, `line must be a 1-based integer, got ${finding.line}`)
  assert.ok(Number.isInteger(finding.column) && finding.column >= 1, `column must be a 1-based integer, got ${finding.column}`)
  assert.ok(typeof finding.frame === "string" && finding.frame.includes("^"), "frame must carry a caret")
}

// --- pinned user-facing strings (DESIGN §0; meta copy corrected per §2.3) -------------------------

test("pinned error strings are preserved verbatim", () => {
  assert.equal(FIRST_META_ERROR, "`export const meta = { name, description, phases }` must be the FIRST statement in the script")
  assert.equal(PURE_META_ERROR, "`export const meta = { name, description }` must be a pure literal with no computed values")
  assert.equal(FORBIDDEN_SOURCE_ERROR, "workflow scripts cannot import modules, access fs, access process, or spawn shell commands")
  assert.equal(
    PLAIN_JS_ERROR,
    "Workflow scripts must be plain JavaScript - TypeScript syntax such as type annotations, interfaces, and generics fails to parse.",
  )
})

// --- v1 false-positive regressions: the AST gate must accept tokens in strings and comments -------

test("prompts containing 'import x from y' and 'require(' are accepted", () => {
  const result = validateCompatibleWorkflowScript(`export const meta = { name: "fp", description: "false positive fixture" }
const r = await agent("Please import x from y, then require('fs') and inspect process.env output", { label: "a" })
return { r }
`)
  assert.equal(result.ok, true, JSON.stringify(result.findings))
  assert.deepStrictEqual(result.findings, [])
})

test("quoted 'fs' / 'child_process' module names in data are accepted", () => {
  const result = validateCompatibleWorkflowScript(`export const meta = { name: "fp", description: "quoted module names" }
const moduleName = "fs"
const banned = ["fs", "child_process", "node:fs"]
const text = 'workflow scripts cannot import modules, access fs, access process, or spawn shell commands'
return agent("explain " + moduleName + " " + banned.join(",") + " " + text, { label: "x" })
`)
  assert.equal(result.ok, true, JSON.stringify(result.findings))
})

test("commented-out forbidden tokens are accepted", () => {
  const result = validateCompatibleWorkflowScript(`export const meta = { name: "fp", description: "commented tokens" }
// import fs from "node:fs"
// const cp = require("child_process")
/* process.exit(1); Buffer.from("x"); with (config) {} */
return agent("do the work", { label: "x" })
`)
  assert.equal(result.ok, true, JSON.stringify(result.findings))
})

// --- real forbidden constructs rejected with line+column+hint -------------------------------------

test("real import declaration is rejected with location and module hint", () => {
  const result = validateCompatibleWorkflowScript(`export const meta = { name: "w", description: "d" }
import fs from "node:fs"
return agent("x", { label: "x" })
`)
  assert.equal(result.ok, false)
  const [finding] = errorsOf(result, "forbidden_source")
  assertLocated(finding)
  assert.equal(finding.message, FORBIDDEN_SOURCE_ERROR)
  assert.equal(finding.line, 2)
  assert.equal(finding.column, 1)
  assert.match(finding.hint ?? "", /'node:fs' is a forbidden module/)
})

test("real require() call is rejected with location and module hint", () => {
  const result = validateCompatibleWorkflowScript(`export const meta = { name: "w", description: "d" }
const cp = require("child_process")
return agent("x", { label: "x" })
`)
  assert.equal(result.ok, false)
  const [finding] = errorsOf(result, "forbidden_source")
  assertLocated(finding)
  assert.equal(finding.message, FORBIDDEN_SOURCE_ERROR)
  assert.equal(finding.line, 2)
  assert.equal(finding.column, 12)
  assert.match(finding.hint ?? "", /'child_process' is a forbidden module/)
})

test("process and Buffer identifier references are rejected with sandbox hint", () => {
  for (const [statement, column] of [["process.exit(1)", 1], ["const b = Buffer.from(\"x\")", 11], ["fetch(\"https://example.com\")", 1]] as const) {
    const result = validateCompatibleWorkflowScript(`export const meta = { name: "w", description: "d" }
${statement}
return agent("x", { label: "x" })
`)
    assert.equal(result.ok, false, statement)
    const [finding] = errorsOf(result, "forbidden_source")
    assertLocated(finding)
    assert.equal(finding.message, FORBIDDEN_SOURCE_ERROR)
    assert.equal(finding.line, 2)
    assert.equal(finding.column, column)
    assert.match(finding.hint ?? "", /sandboxed realm without Node APIs/)
  }
})

test("constructor-chain and eval-style escapes are rejected", () => {
  for (const statement of [
    'agent.constructor.constructor("return process")()',
    '({})["constructor"]["constructor"]("return process.version")()',
    'Function("return process")()',
    'const f = Function; f("return process")()',
    'Reflect.construct(Function, ["return process.version"])()',
    'eval("process")',
    'const e = eval; e("process")',
    'new Function("return process")()',
    "globalThis.process",
  ]) {
    const result = validateCompatibleWorkflowScript(`export const meta = { name: "w", description: "d" }
${statement}
return agent("x", { label: "x" })
`)
    assert.equal(result.ok, false, statement)
    const findings = errorsOf(result, "forbidden_source")
    assert.ok(findings.length >= 1, statement)
    assert.ok(findings.some((finding) => finding.hint?.includes("constructor-chain") || finding.hint?.includes("sandboxed realm")), statement)
  }
})

test("'with' statements are rejected with location and hint", () => {
  // Wrapped scripts are strict-mode, so `with` surfaces at parse level as plain_javascript.
  const result = validateCompatibleWorkflowScript(`export const meta = { name: "w", description: "d" }
const config = { a: 1 }
with (config) { log(a) }
return agent("x", { label: "x" })
`)
  assert.equal(result.ok, false)
  const [finding] = errorsOf(result, "plain_javascript")
  assertLocated(finding)
  assert.equal(finding.line, 3)
  assert.match(finding.message, /'with' in strict mode/)
  assert.ok(finding.hint)
})

test("'await using' declarations are rejected with location and hint", () => {
  const result = validateCompatibleWorkflowScript(`export const meta = { name: "w", description: "d" }
await using handle = getHandle()
return agent("x", { label: "x" })
`)
  assert.equal(result.ok, false)
  const finding = result.findings.find((entry) => entry.code === "plain_javascript" || entry.code === "forbidden_source")
  assertLocated(finding)
  assert.equal(finding.line, 2)
  assert.ok(finding.hint)
})

// --- meta-first / pure-literal -----------------------------------------------------------------

test("meta must be the FIRST statement (exact pinned string)", () => {
  const result = validateCompatibleWorkflowScript(`const early = 1
export const meta = { name: "late", description: "d" }
return agent("x", { label: "x" })
`)
  assert.equal(result.ok, false)
  const [finding] = errorsOf(result, "meta_first")
  assertLocated(finding)
  assert.equal(finding.message, FIRST_META_ERROR)
})

test("meta must be a pure literal (exact pinned string)", () => {
  const result = validateCompatibleWorkflowScript(`export const meta = { name: args.name, description: "d" }
return agent("x", { label: "x" })
`)
  assert.equal(result.ok, false)
  const [finding] = errorsOf(result, "meta_literal")
  assertLocated(finding)
  assert.equal(finding.message, PURE_META_ERROR)
})

test("meta rejects computed keys and reserved keys", () => {
  const computed = validateCompatibleWorkflowScript(`export const meta = { ["na" + "me"]: "x", description: "d" }
return agent("x", { label: "x" })
`)
  assert.equal(computed.ok, false)
  assert.ok(errorsOf(computed, "meta_literal").length >= 1)

  const reserved = validateCompatibleWorkflowScript(`export const meta = { name: "x", description: "d", __proto__: { a: 1 } }
return agent("x", { label: "x" })
`)
  assert.equal(reserved.ok, false)
  assert.ok(errorsOf(reserved, "meta_literal").some((finding) => finding.message.includes('reserved key "__proto__"')))
})

test("meta requires name and description; phases are NOT required", () => {
  const minimal = validateCompatibleWorkflowScript(`export const meta = { name: "minimal", description: "no phases declared" }
return agent("x", { label: "x" })
`)
  assert.equal(minimal.ok, true, JSON.stringify(minimal.findings))

  const missingDescription = validateCompatibleWorkflowScript(`export const meta = { name: "only-name" }
return agent("x", { label: "x" })
`)
  assert.equal(missingDescription.ok, false)
  assert.ok(errorsOf(missingDescription, "meta_literal").some((finding) => finding.message.includes("requires string field description")))

  const missingName = validateCompatibleWorkflowScript(`export const meta = { description: "only description" }
return agent("x", { label: "x" })
`)
  assert.equal(missingName.ok, false)
  assert.ok(errorsOf(missingName, "meta_literal").some((finding) => finding.message.includes("requires string field name")))
})

test("meta with phases array parses through parseWorkflowMeta", () => {
  const meta = parseWorkflowMeta(`export const meta = {
  name: "phased",
  description: "phases stay optional metadata",
  phases: [{ title: "Plan", detail: "Plan it." }, { title: "Apply" }],
}
return agent("x", { label: "x" })
`)
  assert.ok(meta)
  assert.equal(meta.name, "phased")
  assert.equal(meta.phases?.length, 2)
  assert.equal(meta.phases?.[0]?.title, "Plan")
})

// --- plain JavaScript gate ----------------------------------------------------------------------

test("TypeScript syntax produces plain_javascript with the exact pinned suffix", () => {
  const result = validateCompatibleWorkflowScript(`export const meta = { name: "typed", description: "d" }
const files: string[] = []
return agent("x", { label: "x" })
`)
  assert.equal(result.ok, false)
  const [finding] = errorsOf(result, "plain_javascript")
  assertLocated(finding)
  assert.ok(finding.message.startsWith("Script parse error: "), finding.message)
  assert.ok(finding.message.endsWith(PLAIN_JS_ERROR), finding.message)
  assert.equal(finding.line, 2)
})

test("interfaces and generics also fail the plain JavaScript gate", () => {
  for (const statement of ["interface Shape { a: string }", "const pick = <T>(value: T): T => value"]) {
    const result = validateCompatibleWorkflowScript(`export const meta = { name: "typed", description: "d" }
${statement}
return agent("x", { label: "x" })
`)
    assert.equal(result.ok, false, statement)
    assert.ok(errorsOf(result, "plain_javascript").length >= 1, statement)
  }
})

// --- orchestration hook and runner-only helper ---------------------------------------------------

test("missing_orchestration_hook fires when no agent/parallel/pipeline/workflow call exists", () => {
  const result = validateCompatibleWorkflowScript(`export const meta = { name: "no-hooks", description: "d" }
phase("Setup")
log("nothing orchestrated")
return { done: true }
`)
  assert.equal(result.ok, false)
  const [finding] = errorsOf(result, "missing_orchestration_hook")
  assert.ok(finding)
  assert.equal(finding.message, MISSING_HOOK_ERROR)
  assert.ok(finding.hint)
})

test("each orchestration hook satisfies the hook check", () => {
  for (const call of ['agent("x", { label: "x" })', "parallel([() => 1])", "pipeline([1], (item) => item)", 'workflow("child", {})']) {
    const result = validateCompatibleWorkflowScript(`export const meta = { name: "hooked", description: "d" }
return ${call}
`)
    assert.deepStrictEqual(errorsOf(result, "missing_orchestration_hook"), [], call)
  }
})

test("runner_only_helper rejects applyFrontmatter() and pairs with missing hook", () => {
  const result = validateCompatibleWorkflowScript(`export const meta = { name: "bad-frontmatter", description: "Invalid runner-only frontmatter workflow" }
phase("Apply")
function buildTaxonomyPlan() { return { frontmatterPlan: [] } }
const plan = buildTaxonomyPlan()
return applyFrontmatter(plan)
`)
  assert.equal(result.ok, false)
  const [helper] = errorsOf(result, "runner_only_helper")
  assertLocated(helper)
  assert.equal(helper.message, RUNNER_ONLY_HELPER_ERROR)
  assert.equal(errorsOf(result, "missing_orchestration_hook").length, 1)
})

test("member-expression applyFrontmatter is also rejected", () => {
  const result = validateCompatibleWorkflowScript(`export const meta = { name: "bad", description: "d" }
const plan = await agent("plan", { label: "p" })
return helpers.applyFrontmatter(plan)
`)
  assert.equal(result.ok, false)
  assert.equal(errorsOf(result, "runner_only_helper").length, 1)
})

// --- valid end-to-end fixture --------------------------------------------------------------------

test("a representative valid workflow passes the gate cleanly", () => {
  const result = validateCompatibleWorkflowScript(`export const meta = {
  name: "valid",
  description: "Valid workflow",
  phases: [{ title: "Plan", detail: "Use a schema-backed agent." }],
}
phase("Plan")
const results = await pipeline(["README.md"], (path, original, index) =>
  agent("Plan " + path, { label: "plan-" + index, schema: { type: "object", required: ["summary"], properties: { summary: { type: "string" } }, additionalProperties: false } }))
return { results }
`)
  assert.equal(result.ok, true, JSON.stringify(result.findings))
})
