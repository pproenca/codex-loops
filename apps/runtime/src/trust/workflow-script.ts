// Static validation gate (DESIGN §2.3): acorn AST checks over the meta-rewritten, async-wrapped
// script body. Advisory layered defense; the vm membrane in script-host.ts is the enforcement.
import { parse } from "acorn"
import { z } from "zod"

import type { Proven } from "../domain/brand.ts"
import {
  WorkflowValidationError,
  type CompatibleWorkflowScript,
  type WorkflowCompatibilityCode,
  type WorkflowCompatibilityFinding,
  type WorkflowCompatibilityResult,
  type WorkflowMeta,
} from "../domain/contracts.ts"
import { proven } from "./proven.ts"

export const FIRST_META_ERROR = "`export const meta = { name, description, phases }` must be the FIRST statement in the script"
export const PURE_META_ERROR = "`export const meta = { name, description }` must be a pure literal with no computed values"
export const FORBIDDEN_SOURCE_ERROR = "workflow scripts cannot import modules, access fs, access process, or spawn shell commands"
export const PLAIN_JS_ERROR =
  "Workflow scripts must be plain JavaScript - TypeScript syntax such as type annotations, interfaces, and generics fails to parse."
export const RUNNER_ONLY_HELPER_ERROR =
  "Workflow scripts must not call runner-only helper applyFrontmatter(); produce a closed plan and let runner-owned post-processing apply it."
export const MISSING_HOOK_ERROR =
  "Workflow scripts must use workflow orchestration hooks such as agent(), pipeline(), parallel(), or workflow()."

const META_FIRST_HINT = 'declare `export const meta = { name: "...", description: "..." }` before any other statement'
const PLAIN_JS_HINT = "rewrite the script as plain JavaScript; the runner executes it without transpilation"
const SANDBOX_HINT = "workflow scripts run in a sandboxed realm without Node APIs; delegate file, process, and shell work to agent() calls"
const META_LITERAL_HINT = "meta may contain only string, number, boolean, null, array, and plain object literals"
const MISSING_HOOK_HINT = "call agent(), pipeline(), parallel(), or workflow() at least once so the run produces agent work"
const CONSTRUCTOR_ESCAPE_HINT = "workflow scripts cannot use constructor-chain or eval-style code generation; delegate work to agent() calls"

// Mirrors the script-host execution wrapper so the gate parses exactly what the vm will compile.
const WRAP_PREFIX = '"use strict"; const __main = async () => {\n'
const WRAP_SUFFIX = "\n}\n"
const META_EXPORT_PATTERN = /\bexport(\s+const\s+meta\s*=)/
const ORCHESTRATION_HOOKS = new Set(["agent", "parallel", "pipeline", "workflow"])
const FORBIDDEN_MODULES = new Set(["node:fs", "fs", "node:child_process", "child_process"])
const RESERVED_META_KEYS = new Set(["__proto__", "constructor", "prototype"])
const FORBIDDEN_GLOBAL_REFERENCES = new Set(["process", "Buffer", "globalThis", "fetch", "WebSocket", "EventSource"])
const FORBIDDEN_CODEGEN_REFERENCES = new Set(["eval", "Function", "Reflect"])

const workflowMetaSchema = z.object({
  name: z.string().min(1),
  description: z.string().min(1),
  whenToUse: z.string().optional(),
  phases: z.array(z.object({
    title: z.string().min(1),
    detail: z.string().optional(),
    model: z.string().optional(),
  }).strip()).optional(),
}).strip()

type Pos = { line: number; column: number }
type Node = { type: string; start: number; end: number; loc?: { start: Pos; end: Pos } | null }
type IdentifierNode = Node & { name: string }
type LiteralNode = Node & { value: unknown }
type CallExpressionNode = Node & { callee: Node; arguments: Node[] }
type MemberExpressionNode = Node & { object: Node; property: Node; computed: boolean }
type PropertyNode = Node & { key: Node; value: Node; computed: boolean; shorthand: boolean; kind: string; method?: boolean }
type ObjectExpressionNode = Node & { properties: Node[] }
type ArrayExpressionNode = Node & { elements: Array<Node | null> }
type UnaryExpressionNode = Node & { operator: string; argument: Node }
type VariableDeclarationNode = Node & { kind: string; declarations: Node[] }
type VariableDeclaratorNode = Node & { id: Node; init?: Node | null }
type ExportNamedDeclarationNode = Node & { declaration?: Node | null }
type ImportDeclarationNode = Node & { source: Node }
type ImportExpressionNode = Node & { source: Node }
type MetaPropertyNode = Node & { meta: Node; property: Node }
type ProgramNode = Node & { body: Node[] }
type KeyedNode = Node & { key?: Node; computed?: boolean }
type LabeledNode = Node & { label?: Node | null }

type AcornError = Error & { loc?: Pos | undefined }

type Analysis =
  | {
      parsed: true
      program: ProgramNode
      statements: Node[]
      metaObject: ObjectExpressionNode | undefined
      metaExportNode: Node | undefined
      moduleFallback: boolean
      wrappedError: AcornError | undefined
      mapLoc: (pos: Pos) => Pos
    }
  | { parsed: false; error: AcornError; metaExportMatched: boolean }

export function assertCompatibleWorkflowScript(source: string): void {
  parseCompatibleWorkflowScriptSource(source)
}

export function parseCompatibleWorkflowScriptSource(source: string): Proven<CompatibleWorkflowScript> {
  const result = parseWorkflowScriptCompatibility(source)
  const meta = result.ok ? parseWorkflowMeta(source) : undefined
  if (result.ok && meta !== undefined) return proven({ source, meta, compatibility: result })
  const details = result.findings
    .filter((finding) => finding.severity === "error")
    .map((finding) => `${finding.code}: ${finding.message}`)
    .join("; ")
  const message = details.length > 0 ? `Workflow compatibility failed: ${details}` : "Workflow compatibility failed: meta was not parseable"
  throw new WorkflowValidationError(message, result)
}

export function parseWorkflowScriptCompatibility(source: string): Proven<WorkflowCompatibilityResult> {
  return proven(validateCompatibleWorkflowScript(source))
}

export function validateCompatibleWorkflowScript(source: string): WorkflowCompatibilityResult {
  const lines = source.split("\n")
  const findings: WorkflowCompatibilityFinding[] = []
  const seen = new Set<string>()
  const push = (code: WorkflowCompatibilityCode, message: string, at?: Pos | undefined, hint?: string): void => {
    const line = Math.min(Math.max(at?.line ?? 1, 1), Math.max(lines.length, 1))
    const column = Math.max(at?.column ?? 1, 1)
    const key = `${code}\u0000${message}\u0000${line}\u0000${column}`
    if (seen.has(key)) return
    seen.add(key)
    findings.push({ severity: "error", code, message, line, column, frame: buildFrame(lines, line, column), ...(hint === undefined ? {} : { hint }) })
  }

  const analysis = analyzeScript(source)
  if (!analysis.parsed) {
    if (!analysis.metaExportMatched) push("meta_first", FIRST_META_ERROR, undefined, META_FIRST_HINT)
    const at = analysis.error.loc ? { line: analysis.error.loc.line, column: analysis.error.loc.column + 1 } : undefined
    push("plain_javascript", `Script parse error: ${parseErrorMessage(analysis.error)} ${PLAIN_JS_ERROR}`, at, PLAIN_JS_HINT)
    return { ok: false, findings }
  }

  const locate = (node: Node | undefined): Pos | undefined => (node?.loc ? analysis.mapLoc(node.loc.start) : undefined)

  if (!analysis.metaObject) push("meta_first", FIRST_META_ERROR, locate(analysis.statements[0]), META_FIRST_HINT)

  let hookSeen = false
  let moduleSyntaxFound = false
  let strayExport: Node | undefined

  walk(analysis.program, undefined, (node, parent) => {
    switch (node.type) {
      case "ImportDeclaration":
        moduleSyntaxFound = true
        push("forbidden_source", FORBIDDEN_SOURCE_ERROR, locate(node), moduleHint(literalString((node as ImportDeclarationNode).source)))
        return
      case "ImportExpression":
        push("forbidden_source", "import() is not available in workflow scripts.", locate(node), moduleHint(literalString((node as ImportExpressionNode).source)))
        return
      case "MetaProperty":
        if (((node as MetaPropertyNode).meta as IdentifierNode).name === "import") {
          moduleSyntaxFound = true
          push("forbidden_source", FORBIDDEN_SOURCE_ERROR, locate(node), SANDBOX_HINT)
        }
        return
      case "ExportNamedDeclaration":
      case "ExportDefaultDeclaration":
      case "ExportAllDeclaration":
        if (node !== analysis.metaExportNode) strayExport ??= node
        return
      case "WithStatement":
        push("forbidden_source", "'with' statements are not supported in workflow scripts.", locate(node), SANDBOX_HINT)
        return
      case "VariableDeclaration":
        if ((node as VariableDeclarationNode).kind === "await using") {
          push("forbidden_source", "'await using' declarations are not supported in workflow scripts.", locate(node), SANDBOX_HINT)
        }
        return
      case "CallExpression": {
        const call = node as CallExpressionNode
        if (call.callee.type === "Identifier") {
          const name = (call.callee as IdentifierNode).name
          if (name === "require") {
            push("forbidden_source", FORBIDDEN_SOURCE_ERROR, locate(node), moduleHint(literalString(call.arguments[0])))
            return
          }
          if (FORBIDDEN_CODEGEN_REFERENCES.has(name)) {
            push("forbidden_source", FORBIDDEN_SOURCE_ERROR, locate(node), CONSTRUCTOR_ESCAPE_HINT)
            return
          }
          if (ORCHESTRATION_HOOKS.has(name)) hookSeen = true
          if (name === "applyFrontmatter") push("runner_only_helper", RUNNER_ONLY_HELPER_ERROR, locate(node))
          return
        }
        if (call.callee.type === "MemberExpression") {
          const member = call.callee as MemberExpressionNode
          if (!member.computed && member.property.type === "Identifier" && (member.property as IdentifierNode).name === "applyFrontmatter") {
            push("runner_only_helper", RUNNER_ONLY_HELPER_ERROR, locate(node))
          }
        }
        return
      }
      case "NewExpression":
        if ((node as CallExpressionNode).callee.type === "Identifier" && FORBIDDEN_CODEGEN_REFERENCES.has(((node as CallExpressionNode).callee as IdentifierNode).name)) {
          push("forbidden_source", FORBIDDEN_SOURCE_ERROR, locate(node), CONSTRUCTOR_ESCAPE_HINT)
        }
        return
      case "MemberExpression": {
        const member = node as MemberExpressionNode
        if (memberName(member) === "constructor") {
          push("forbidden_source", FORBIDDEN_SOURCE_ERROR, locate(node), CONSTRUCTOR_ESCAPE_HINT)
        }
        return
      }
      case "Identifier": {
        const name = (node as IdentifierNode).name
        if (FORBIDDEN_CODEGEN_REFERENCES.has(name) && isBindingReference(node, parent)) {
          push("forbidden_source", FORBIDDEN_SOURCE_ERROR, locate(node), CONSTRUCTOR_ESCAPE_HINT)
          return
        }
        if (FORBIDDEN_GLOBAL_REFERENCES.has(name) && isBindingReference(node, parent)) {
          push("forbidden_source", FORBIDDEN_SOURCE_ERROR, locate(node), SANDBOX_HINT)
        }
        return
      }
      default:
        return
    }
  })

  // Module-only syntax forced the fallback parse; surface why the execution wrapper would fail to compile.
  if (analysis.moduleFallback && analysis.wrappedError) {
    if (strayExport) {
      push("plain_javascript", `Script parse error: ${parseErrorMessage(analysis.wrappedError)} ${PLAIN_JS_ERROR}`, locate(strayExport), PLAIN_JS_HINT)
    } else if (!moduleSyntaxFound) {
      const loc = analysis.wrappedError.loc
      const at = loc ? { line: loc.line - 1, column: loc.column + 1 } : undefined
      push("plain_javascript", `Script parse error: ${parseErrorMessage(analysis.wrappedError)} ${PLAIN_JS_ERROR}`, at, PLAIN_JS_HINT)
    }
  }

  if (analysis.metaObject) {
    const metaObject = analysis.metaObject
    checkMetaLiteral(metaObject, (message, node) => push("meta_literal", message, locate(node), META_LITERAL_HINT))
    let metaValue: Record<string, unknown> | undefined
    try {
      metaValue = buildMetaValue(metaObject) as Record<string, unknown>
    } catch {
      metaValue = undefined // impure literal; findings already recorded above
    }
    if (metaValue) {
      const name = metaValue["name"]
      if (typeof name !== "string" || name.trim() === "") {
        push("meta_literal", "workflow meta requires string field name", locate(findMetaProperty(metaObject, "name") ?? metaObject))
      }
      const description = metaValue["description"]
      if (typeof description !== "string" || description.trim() === "") {
        push("meta_literal", "workflow meta requires string field description", locate(findMetaProperty(metaObject, "description") ?? metaObject))
      }
    }
  }

  if (!hookSeen) push("missing_orchestration_hook", MISSING_HOOK_ERROR, undefined, MISSING_HOOK_HINT)

  return { ok: findings.every((finding) => finding.severity !== "error"), findings }
}

export function parseWorkflowMeta(source: string): WorkflowMeta | undefined {
  const analysis = analyzeScript(source)
  if (!analysis.parsed || !analysis.metaObject) return undefined
  const value = buildMetaValue(analysis.metaObject)
  const parsed = workflowMetaSchema.safeParse(value)
  return parsed.success ? parsed.data : undefined
}

// --- parsing ----------------------------------------------------------------------------------

function analyzeScript(source: string): Analysis {
  const match = META_EXPORT_PATTERN.exec(source)
  // Blank the `export` keyword in place so original line/column offsets are preserved exactly.
  const rewritten = match ? `${source.slice(0, match.index)}      ${source.slice(match.index + 6)}` : source
  let wrappedError: AcornError | undefined
  try {
    const program = parseProgram(WRAP_PREFIX + rewritten + WRAP_SUFFIX, "script")
    const statements = unwrapMain(program)
    const first = statements[0]
    const firstStart = first ? first.start - WRAP_PREFIX.length : -1
    const exportSeen =
      match !== null && first !== undefined && match.index < firstStart && /^export\s+$/.test(source.slice(match.index, firstStart))
    return {
      parsed: true,
      program,
      statements,
      metaObject: exportSeen ? metaDeclarationOf(first) : undefined,
      metaExportNode: undefined,
      moduleFallback: false,
      wrappedError: undefined,
      mapLoc: (pos) => ({ line: pos.line - 1, column: pos.column + 1 }),
    }
  } catch (error) {
    wrappedError = error as AcornError
  }
  try {
    const program = parseProgram(source, "module")
    const first = program.body[0]
    let metaExportNode: Node | undefined
    let metaObject: ObjectExpressionNode | undefined
    if (first && first.type === "ExportNamedDeclaration") {
      metaObject = metaDeclarationOf((first as ExportNamedDeclarationNode).declaration ?? undefined)
      if (metaObject) metaExportNode = first
    }
    return {
      parsed: true,
      program,
      statements: program.body,
      metaObject,
      metaExportNode,
      moduleFallback: true,
      wrappedError,
      mapLoc: (pos) => ({ line: pos.line, column: pos.column + 1 }),
    }
  } catch (error) {
    return { parsed: false, error: error as AcornError, metaExportMatched: match !== null }
  }
}

function parseProgram(source: string, sourceType: "script" | "module"): ProgramNode {
  return parse(source, {
    ecmaVersion: 2024,
    sourceType,
    locations: true,
    allowReturnOutsideFunction: sourceType === "module",
  }) as unknown as ProgramNode
}

function unwrapMain(program: ProgramNode): Node[] {
  const declaration = program.body[1] as VariableDeclarationNode | undefined
  const declarator = declaration?.declarations[0] as VariableDeclaratorNode | undefined
  const arrow = (declarator?.init ?? undefined) as (Node & { body?: Node }) | undefined
  const block = arrow?.body as (Node & { body?: Node[] }) | undefined
  return block?.body ?? []
}

function metaDeclarationOf(node: Node | undefined): ObjectExpressionNode | undefined {
  if (!node || node.type !== "VariableDeclaration") return undefined
  const declaration = node as VariableDeclarationNode
  if (declaration.kind !== "const") return undefined
  const declarator = declaration.declarations[0] as VariableDeclaratorNode | undefined
  if (!declarator || declarator.id.type !== "Identifier" || (declarator.id as IdentifierNode).name !== "meta") return undefined
  const init = declarator.init ?? undefined
  return init && init.type === "ObjectExpression" ? (init as ObjectExpressionNode) : undefined
}

// --- AST traversal ----------------------------------------------------------------------------

function walk(node: Node, parent: Node | undefined, visit: (node: Node, parent: Node | undefined) => void): void {
  visit(node, parent)
  for (const [key, value] of Object.entries(node as unknown as Record<string, unknown>)) {
    if (key === "loc") continue
    if (Array.isArray(value)) {
      for (const item of value) if (isNode(item)) walk(item, node, visit)
    } else if (isNode(value)) {
      walk(value, node, visit)
    }
  }
}

function isNode(value: unknown): value is Node {
  return typeof value === "object" && value !== null && typeof (value as { type?: unknown }).type === "string"
}

function isBindingReference(node: Node, parent: Node | undefined): boolean {
  if (!parent) return true
  if (parent.type === "MemberExpression") {
    const member = parent as MemberExpressionNode
    return member.property !== node || member.computed
  }
  if (parent.type === "Property") {
    const property = parent as PropertyNode
    return property.key !== node || property.computed || property.shorthand
  }
  if (parent.type === "PropertyDefinition" || parent.type === "MethodDefinition") {
    const keyed = parent as KeyedNode
    return keyed.key !== node || keyed.computed === true
  }
  if (parent.type === "LabeledStatement" || parent.type === "BreakStatement" || parent.type === "ContinueStatement") {
    return (parent as LabeledNode).label !== node
  }
  if (
    parent.type === "ImportSpecifier" ||
    parent.type === "ImportDefaultSpecifier" ||
    parent.type === "ImportNamespaceSpecifier" ||
    parent.type === "ExportSpecifier"
  ) {
    return false
  }
  return true
}

// --- meta literal -----------------------------------------------------------------------------

function checkMetaLiteral(meta: ObjectExpressionNode, report: (message: string, node: Node) => void): void {
  const visit = (node: Node): void => {
    switch (node.type) {
      case "Literal": {
        const value = (node as LiteralNode).value
        if (value !== null && typeof value !== "string" && typeof value !== "number" && typeof value !== "boolean") {
          report(PURE_META_ERROR, node)
        }
        return
      }
      case "UnaryExpression": {
        const unary = node as UnaryExpressionNode
        if (unary.operator !== "-" || unary.argument.type !== "Literal" || typeof (unary.argument as LiteralNode).value !== "number") {
          report(PURE_META_ERROR, node)
        }
        return
      }
      case "ArrayExpression": {
        for (const element of (node as ArrayExpressionNode).elements) {
          if (!element) report(PURE_META_ERROR, node)
          else visit(element)
        }
        return
      }
      case "ObjectExpression": {
        for (const entry of (node as ObjectExpressionNode).properties) {
          if (entry.type !== "Property") {
            report(PURE_META_ERROR, entry)
            continue
          }
          const property = entry as PropertyNode
          if (property.computed || property.kind !== "init" || property.method === true) {
            report(PURE_META_ERROR, entry)
            continue
          }
          const key = propertyKeyName(property)
          if (key === undefined) {
            report(PURE_META_ERROR, property.key)
            continue
          }
          if (RESERVED_META_KEYS.has(key)) {
            report(`workflow meta must not include reserved key "${key}"`, property.key)
            continue
          }
          visit(property.value)
        }
        return
      }
      default:
        report(PURE_META_ERROR, node)
    }
  }
  visit(meta)
}

function buildMetaValue(node: Node): unknown {
  switch (node.type) {
    case "Literal": {
      const value = (node as LiteralNode).value
      if (value === null || typeof value === "string" || typeof value === "number" || typeof value === "boolean") return value
      throw new Error(PURE_META_ERROR)
    }
    case "UnaryExpression": {
      const unary = node as UnaryExpressionNode
      if (unary.operator === "-" && unary.argument.type === "Literal") {
        const value = (unary.argument as LiteralNode).value
        if (typeof value === "number") return -value
      }
      throw new Error(PURE_META_ERROR)
    }
    case "ArrayExpression":
      return (node as ArrayExpressionNode).elements.map((element) => {
        if (!element) throw new Error(PURE_META_ERROR)
        return buildMetaValue(element)
      })
    case "ObjectExpression": {
      const entries: Array<[string, unknown]> = []
      for (const entry of (node as ObjectExpressionNode).properties) {
        if (entry.type !== "Property") throw new Error(PURE_META_ERROR)
        const property = entry as PropertyNode
        if (property.computed || property.kind !== "init" || property.method === true) throw new Error(PURE_META_ERROR)
        const key = propertyKeyName(property)
        if (key === undefined) throw new Error(PURE_META_ERROR)
        entries.push([key, buildMetaValue(property.value)])
      }
      // Object.fromEntries uses CreateDataProperty, so a literal "__proto__" key cannot pollute prototypes.
      return Object.fromEntries(entries)
    }
    default:
      throw new Error(PURE_META_ERROR)
  }
}

function propertyKeyName(property: PropertyNode): string | undefined {
  if (property.key.type === "Identifier") return (property.key as IdentifierNode).name
  if (property.key.type === "Literal") {
    const value = (property.key as LiteralNode).value
    if (typeof value === "string" || typeof value === "number") return String(value)
  }
  return undefined
}

function memberName(member: MemberExpressionNode): string | undefined {
  if (!member.computed && member.property.type === "Identifier") return (member.property as IdentifierNode).name
  return literalString(member.property)
}

function findMetaProperty(meta: ObjectExpressionNode, name: string): Node | undefined {
  for (const entry of meta.properties) {
    if (entry.type !== "Property") continue
    const property = entry as PropertyNode
    if (!property.computed && propertyKeyName(property) === name) return property.key
  }
  return undefined
}

// --- diagnostics ------------------------------------------------------------------------------

function literalString(node: Node | undefined): string | undefined {
  if (!node || node.type !== "Literal") return undefined
  const value = (node as LiteralNode).value
  return typeof value === "string" ? value : undefined
}

function moduleHint(specifier: string | undefined): string {
  return specifier !== undefined && FORBIDDEN_MODULES.has(specifier) ? `'${specifier}' is a forbidden module; ${SANDBOX_HINT}` : SANDBOX_HINT
}

function parseErrorMessage(error: AcornError): string {
  return (error.message || String(error)).replace(/ \(\d+:\d+\)$/, "")
}

function buildFrame(lines: string[], line: number, column: number): string {
  const text = (lines[line - 1] ?? "").replace(/\r$/, "")
  const gutter = String(line)
  const caret = " ".repeat(Math.max(0, Math.min(column - 1, text.length)))
  return `${gutter} | ${text}\n${" ".repeat(gutter.length)} | ${caret}^`
}
