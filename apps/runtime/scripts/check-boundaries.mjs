#!/usr/bin/env node
import { readdir, readFile } from "node:fs/promises"
import { builtinModules } from "node:module"
import { dirname, extname, join, relative, resolve, sep } from "node:path"
import { fileURLToPath } from "node:url"
import ts from "typescript"

const appRoot = resolve(fileURLToPath(new URL("..", import.meta.url)))
const srcRoot = resolve(appRoot, process.argv[2] ?? "src")
const builtins = new Set([...builtinModules, ...builtinModules.map((name) => `node:${name}`)])

const layerImports = new Map([
  ["domain", new Set(["domain"])],
  ["trust", new Set(["domain", "trust"])],
  ["core", new Set(["domain", "core"])],
  ["ports", new Set(["domain", "ports"])],
  ["consistency", new Set(["domain", "trust", "ports", "consistency"])],
  ["containment", new Set(["domain", "ports", "containment"])],
  ["app", new Set(["domain", "trust", "core", "ports", "consistency", "containment", "app"])],
  ["effects", new Set(["domain", "ports", "containment", "effects"])],
  ["entry", new Set(["domain", "trust", "app", "ports", "consistency", "effects", "entry"])],
])

const nodeAllowed = new Set(["effects", "consistency", "containment", "entry"])
const unknownAllowed = new Set(["trust", "ports", "effects", "entry"])
const parserSyntaxAllowed = new Set(["trust"])
const fsModules = new Set(["fs", "fs/promises", "node:fs", "node:fs/promises"])
const childProcessModules = new Set(["child_process", "node:child_process"])
const readOnlyFsImports = new Set(["access", "readFile", "readdir", "stat"])
const effectPolicyIdentifiers = new Set(["DEFAULT_LIMITS", "WorkflowLimits", "budgetPlan", "runtimeContract"])
const childRuntimeAllowedImports = new Set(["node:readline"])
const childRuntimeAllowedProcessProperties = new Set(["stdin", "stdout", "exitCode"])

const violations = []

for (const file of await listTsFiles(srcRoot)) {
  const sourceText = await readFile(file, "utf8")
  const layer = layerOf(file)
  const source = ts.createSourceFile(file, sourceText, ts.ScriptTarget.Latest, true, ts.ScriptKind.TS)
  inspectEmbeddedWorkflowChildSources(file, source)
  const importInfo = inspectImports(file, layer, source)
  inspectSyntax(file, layer, source, importInfo)
}

if (violations.length > 0) {
  process.stderr.write(`${violations.length} boundary violation(s):\n`)
  for (const violation of violations) process.stderr.write(`- ${violation}\n`)
  process.exit(1)
}

process.stdout.write("boundary checks passed\n")

async function listTsFiles(dir) {
  const entries = await readdir(dir, { withFileTypes: true })
  const files = []
  for (const entry of entries) {
    const path = join(dir, entry.name)
    if (entry.isDirectory()) files.push(...await listTsFiles(path))
    if (entry.isFile() && extname(entry.name) === ".ts") files.push(path)
  }
  return files
}

function inspectImports(file, layer, source) {
  let importsCodexSdk = false
  const containedTurnHelperNames = containmentHelperLocalNames(file, source)
  const importsContainedTurnHelper = containedTurnHelperNames.size > 0
  for (const statement of source.statements) {
    if (ts.isImportDeclaration(statement) || ts.isExportDeclaration(statement)) {
      const specifier = statement.moduleSpecifier
      if (!specifier || !ts.isStringLiteral(specifier)) continue
      if (specifier.text === "@openai/codex-sdk") importsCodexSdk = true
      checkImport(file, layer, specifier.text, statement)
    }
  }
  if (layer === "effects" && importsCodexSdk && !importsContainedTurnHelper) {
    fail(file, "effects importing @openai/codex-sdk must import runContainedAgentTurn")
  }
  return {
    importsCodexSdk,
    sdkLocalNames: sdkLocalNames(source),
    containedTurnHelperNames,
    journalStoreTypeNames: journalStoreTypeNames(file, source),
    journalStoreNamespaces: journalStoreNamespaces(file, source),
    journalReaderTypeNames: importedPortTypeNames(file, source, "JournalReader"),
    journalDirectoryTypeNames: importedPortTypeNames(file, source, "JournalDirectoryPort"),
  }
}

function checkImport(file, layer, specifier, statement) {
  if (specifier === "zod") {
    if (layer !== "trust") fail(file, "only trust/* may import zod")
    return
  }
  if (specifier === "acorn") {
    if (relative(srcRoot, file) !== join("trust", "workflow-script.ts")) fail(file, "only trust/workflow-script.ts may import acorn")
    return
  }
  if (specifier === "@openai/codex-sdk") {
    if (layer !== "effects") fail(file, "only effects/* may import @openai/codex-sdk")
    return
  }
  if (builtins.has(specifier)) {
    if (specifier === "vm" || specifier === "node:vm") {
      fail(file, "in-process VM execution is not allowed; workflow execution must use an isolated process boundary")
      return
    }
    if (childProcessModules.has(specifier) && layer !== "containment") {
      fail(file, `${layer} may not import ${specifier}; subprocesses must go through containment/*`)
      return
    }
    if (fsModules.has(specifier) && layer !== "consistency") {
      if (layer === "effects" && isReadOnlyFsImport(statement)) return
      fail(file, `${layer} may not import ${specifier}; journal/file writes must go through consistency/*`)
      return
    }
    if (!nodeAllowed.has(layer)) fail(file, `${layer} may not import ${specifier}`)
    return
  }
  if (!specifier.startsWith(".")) return
  if (specifier.endsWith("/trust/proven.ts") || specifier.endsWith("/trust/proven")) {
    if (layer !== "trust") fail(file, "only trust/* may import the Proven minting helper")
  }
  const targetLayer = layerOf(resolve(dirname(file), specifier))
  if (layer === "effects" && (targetLayer === "trust" || specifier.replaceAll("\\", "/").includes("/trust/"))) {
    fail(file, "effects may not import trust parsers")
  }
  const allowed = layerImports.get(layer)
  if (!allowed?.has(targetLayer)) fail(file, `${layer} may not import ${targetLayer} via ${specifier}`)
}

function inspectSyntax(file, layer, source, importInfo) {
  let callsContainedTurnHelper = false
  const visit = (node, insideContainedOperation = false) => {
    const declaredName = declaredIdentifierName(node)
    if (declaredName !== undefined && importInfo.containedTurnHelperNames.has(declaredName)) {
      failAt(file, source, node, "shadowing runContainedAgentTurn is not allowed")
    }
    if (
      ts.isCallExpression(node)
      && ts.isIdentifier(node.expression)
      && importInfo.containedTurnHelperNames.has(node.expression.text)
    ) {
      callsContainedTurnHelper = true
      for (const child of containedTurnChildren(node)) visit(child.node, child.insideContainedOperation)
      return
    }
    if (!insideContainedOperation && sdkCallRoot(node) !== undefined && importInfo.sdkLocalNames.has(sdkCallRoot(node))) {
      failAt(file, source, node, "SDK calls must occur inside runContainedAgentTurn operation")
    }
    if (!parserSyntaxAllowed.has(layer)) {
      if (ts.isVariableDeclaration(node) && aliasesJsonParse(node)) failAt(file, source, node, "JSON.parse aliases are only allowed in trust/*")
      if (ts.isVariableDeclaration(node) && aliasesSdkImport(node, importInfo.sdkLocalNames)) failAt(file, source, node, "SDK aliases are only allowed inside containment-aware effects")
      if (node.kind === ts.SyntaxKind.TypeOfExpression) failAt(file, source, node, "typeof is only allowed in trust/*")
      if (ts.isBinaryExpression(node) && node.operatorToken.kind === ts.SyntaxKind.InstanceOfKeyword) failAt(file, source, node, "instanceof is only allowed in trust/*")
      if (ts.isBinaryExpression(node) && node.operatorToken.kind === ts.SyntaxKind.InKeyword) failAt(file, source, node, "in checks are only allowed in trust/*")
      if (ts.isAsExpression(node) || ts.isTypeAssertionExpression(node)) failAt(file, source, node, "type assertions are only allowed in trust/*")
      if (ts.isNonNullExpression(node)) failAt(file, source, node, "non-null assertions are only allowed in trust/*")
      if (ts.isCallExpression(node) && isArrayIsArray(node.expression)) failAt(file, source, node, "Array.isArray is only allowed in trust/*")
      if (ts.isCallExpression(node) && isJsonParse(node.expression)) failAt(file, source, node, "JSON.parse is only allowed in trust/*")
      if (ts.isCallExpression(node) && isDynamicImport(node.expression)) failAt(file, source, node, "dynamic import is only allowed in trust/*")
      if (ts.isCallExpression(node) && isRequireCall(node.expression)) failAt(file, source, node, "require is only allowed in trust/*")
      if (ts.isIdentifier(node) && node.text === "compact") failAt(file, source, node, "compact helpers are only allowed in trust/*")
      if (ts.isIdentifier(node) && node.text === "proven") failAt(file, source, node, "Proven minting is only allowed in trust/*")
      if (ts.isParameter(node) && node.initializer) failAt(file, source, node, "parameter defaults are only allowed in trust/*")
      if (ts.isBinaryExpression(node) && node.operatorToken.kind === ts.SyntaxKind.QuestionQuestionToken) failAt(file, source, node, "nullish defaulting is only allowed in trust/*")
    }
    if (!unknownAllowed.has(layer) && node.kind === ts.SyntaxKind.UnknownKeyword) {
      failAt(file, source, node, "unknown is only allowed at trust/effects/entry boundaries")
    }
    if (layer === "effects" && ts.isIdentifier(node) && effectPolicyIdentifiers.has(node.text)) {
      failAt(file, source, node, "workflow policy/default construction belongs in core/*, not effects/*")
    }
    if (!nodeAllowed.has(layer) && ts.isIdentifier(node) && (node.text === "process" || node.text === "Date")) {
      failAt(file, source, node, `${node.text} is only allowed at effect/consistency/containment/entry rims`)
    }
    if (!nodeAllowed.has(layer) && ts.isIdentifier(node) && (node.text === "fetch" || node.text === "setTimeout" || node.text === "setInterval")) {
      failAt(file, source, node, `${node.text} is only allowed at effect/consistency/containment/entry rims`)
    }
    if (layer !== "consistency" && ts.isHeritageClause(node)) {
      for (const type of node.types) {
        const expressionText = type.expression.getText(source)
        if (
          importInfo.journalStoreTypeNames.has(expressionText)
          || [...importInfo.journalStoreNamespaces].some((name) => expressionText === `${name}.JournalStore`)
        ) {
          failAt(file, source, type, "JournalStore implementations are only allowed in consistency/*")
        }
      }
    }
    if (layer !== "effects" && ts.isHeritageClause(node)) {
      for (const type of node.types) {
        const expressionText = type.expression.getText(source)
        if (importInfo.journalReaderTypeNames.has(expressionText)) {
          failAt(file, source, type, "JournalReader implementations are only allowed in effects/*")
        }
        if (importInfo.journalDirectoryTypeNames.has(expressionText)) {
          failAt(file, source, type, "JournalDirectoryPort implementations are only allowed in effects/*")
        }
      }
    }
    if (layer !== "consistency" && ts.isObjectLiteralExpression(node) && hasProperty(node, "commit") && hasProperty(node, "initializeRun")) {
      failAt(file, source, node, "JournalStore-shaped object literals are only allowed in consistency/*")
    }
    if (layer !== "consistency" && ts.isClassDeclaration(node) && hasClassMember(node, "commit") && hasClassMember(node, "initializeRun")) {
      failAt(file, source, node, "JournalStore-shaped classes are only allowed in consistency/*")
    }
    if (layer !== "effects" && ts.isClassDeclaration(node) && hasClassMember(node, "readText") && hasClassMember(node, "readPointerTarget")) {
      failAt(file, source, node, "JournalReader-shaped classes are only allowed in effects/*")
    }
    if (layer !== "effects" && ts.isObjectLiteralExpression(node) && hasProperty(node, "readText") && hasProperty(node, "readPointerTarget")) {
      failAt(file, source, node, "JournalReader-shaped object literals are only allowed in effects/*")
    }
    if (layer !== "effects" && ts.isClassDeclaration(node) && hasClassMember(node, "listJournalFiles")) {
      failAt(file, source, node, "JournalDirectory-shaped classes are only allowed in effects/*")
    }
    if (layer !== "effects" && ts.isObjectLiteralExpression(node) && hasProperty(node, "listJournalFiles")) {
      failAt(file, source, node, "JournalDirectory-shaped object literals are only allowed in effects/*")
    }
    ts.forEachChild(node, (child) => visit(child, insideContainedOperation))
  }
  visit(source)
  if (layer === "effects" && importInfo.importsCodexSdk && !callsContainedTurnHelper) {
    fail(file, "effects importing @openai/codex-sdk must call runContainedAgentTurn")
  }
}

function inspectEmbeddedWorkflowChildSources(file, source) {
  const visit = (node) => {
    if (ts.isVariableDeclaration(node) && ts.isIdentifier(node.name) && node.name.text === "WORKFLOW_CHILD_SOURCE") {
      const text = childRuntimeSourceText(node.initializer)
      if (text === undefined) {
        failAt(file, source, node, "WORKFLOW_CHILD_SOURCE must be a statically inspectable String.raw template")
      } else {
        inspectWorkflowChildRuntimeSource(file, text)
      }
    }
    ts.forEachChild(node, visit)
  }
  visit(source)
}

function childRuntimeSourceText(initializer) {
  if (!initializer) return undefined
  if (ts.isNoSubstitutionTemplateLiteral(initializer)) return initializer.text
  if (
    ts.isTaggedTemplateExpression(initializer)
    && initializer.tag.getText() === "String.raw"
    && ts.isNoSubstitutionTemplateLiteral(initializer.template)
  ) {
    return initializer.template.text
  }
  return undefined
}

function inspectWorkflowChildRuntimeSource(file, text) {
  const runtime = ts.createSourceFile(`${file}.workflow-child.js`, text, ts.ScriptTarget.Latest, true, ts.ScriptKind.JS)
  let jsonIngressParseCount = 0
  let jsonResponseParseCount = 0
  let jsonRoundTripParseCount = 0
  const visit = (node) => {
    if (ts.isImportDeclaration(node)) {
      const specifier = node.moduleSpecifier
      if (!specifier || !ts.isStringLiteral(specifier) || !childRuntimeAllowedImports.has(specifier.text)) {
        failAtEmbedded(file, runtime, node, "workflow child runtime may only import node:readline")
      }
    }
    if (ts.isCallExpression(node) && isJsonParse(node.expression)) {
      const [argument] = node.arguments
      if (argument && ts.isCallExpression(argument) && isJsonStringify(argument.expression)) {
        jsonRoundTripParseCount += 1
      } else if (argument && isLineSliceCall(argument)) {
        jsonResponseParseCount += 1
      } else {
        jsonIngressParseCount += 1
      }
    }
    if (ts.isCallExpression(node) && isArrayIsArray(node.expression)) {
      failAtEmbedded(file, runtime, node, "workflow child runtime must not locally validate arrays; host/core owns workflow policy")
    }
    if (ts.isCallExpression(node) && isPromiseAll(node.expression)) {
      failAtEmbedded(file, runtime, node, "workflow child runtime must not schedule with Promise.all; host/core owns workflow policy")
    }
    if (isMessagePropertyRead(node)) {
      failAtEmbedded(file, runtime, node, "workflow child runtime must not inspect raw parsed response object fields")
    }
    if (ts.isCallExpression(node) && isDynamicImport(node.expression)) {
      failAtEmbedded(file, runtime, node, "workflow child runtime may not use dynamic import")
    }
    if (ts.isCallExpression(node) && isRequireCall(node.expression)) {
      failAtEmbedded(file, runtime, node, "workflow child runtime may not use require")
    }
    if (ts.isCallExpression(node) && ts.isIdentifier(node.expression) && node.expression.text === "eval") {
      failAtEmbedded(file, runtime, node, "workflow child runtime may not use eval")
    }
    if (ts.isNewExpression(node) && ts.isIdentifier(node.expression) && node.expression.text === "Function") {
      failAtEmbedded(file, runtime, node, "workflow child runtime may not construct Function directly")
    }
    if (ts.isIdentifier(node) && node.text === "process" && !isAllowedChildProcessUse(node)) {
      failAtEmbedded(file, runtime, node, "workflow child runtime process access is limited to stdio and exitCode")
    }
    ts.forEachChild(node, visit)
  }
  visit(runtime)
  if (jsonIngressParseCount !== 1) {
    fail(file, `workflow child runtime must contain exactly one JSON.parse ingress; found ${jsonIngressParseCount}`)
  }
  if (jsonResponseParseCount !== 1) {
    fail(file, `workflow child runtime must contain exactly one JSON.parse host response payload parse; found ${jsonResponseParseCount}`)
  }
  if (jsonRoundTripParseCount !== 1) {
    fail(file, `workflow child runtime must contain exactly one JSON.parse(JSON.stringify(...)) JSON boundary; found ${jsonRoundTripParseCount}`)
  }
}

function isAllowedChildProcessUse(node) {
  const parent = node.parent
  return ts.isPropertyAccessExpression(parent)
    && parent.expression === node
    && childRuntimeAllowedProcessProperties.has(parent.name.text)
}

function containedTurnChildren(node) {
  const [input] = node.arguments
  const children = [{ node: node.expression, insideContainedOperation: false }]
  for (const argument of node.arguments) {
    if (argument === input && ts.isObjectLiteralExpression(argument)) {
      for (const property of argument.properties) children.push({
        node: property,
        insideContainedOperation: isPropertyNamed(property, "operation"),
      })
    } else {
      children.push({ node: argument, insideContainedOperation: false })
    }
  }
  return children
}

function sdkCallRoot(node) {
  if (ts.isCallExpression(node) || ts.isNewExpression(node)) return sdkExpressionRoot(node.expression)
  return undefined
}

function sdkExpressionRoot(expression) {
  if (ts.isIdentifier(expression)) return expression.text
  if (ts.isPropertyAccessExpression(expression) || ts.isElementAccessExpression(expression)) return sdkExpressionRoot(expression.expression)
  return undefined
}

function isArrayIsArray(expression) {
  return ts.isPropertyAccessExpression(expression)
    && ts.isIdentifier(expression.expression)
    && expression.expression.text === "Array"
    && expression.name.text === "isArray"
}

function isJsonParse(expression) {
  if (ts.isPropertyAccessExpression(expression)) {
    return ts.isIdentifier(expression.expression)
      && expression.expression.text === "JSON"
      && expression.name.text === "parse"
  }
  return ts.isElementAccessExpression(expression)
    && ts.isIdentifier(expression.expression)
    && expression.expression.text === "JSON"
    && ts.isStringLiteral(expression.argumentExpression)
    && expression.argumentExpression.text === "parse"
}

function isJsonStringify(expression) {
  if (!ts.isPropertyAccessExpression(expression)) return false
  return ts.isIdentifier(expression.expression)
    && expression.expression.text === "JSON"
    && expression.name.text === "stringify"
}

function isLineSliceCall(node) {
  return ts.isCallExpression(node)
    && ts.isPropertyAccessExpression(node.expression)
    && ts.isIdentifier(node.expression.expression)
    && node.expression.expression.text === "line"
    && node.expression.name.text === "slice"
}

function isPromiseAll(expression) {
  return ts.isPropertyAccessExpression(expression)
    && ts.isIdentifier(expression.expression)
    && expression.expression.text === "Promise"
    && expression.name.text === "all"
}

function isMessagePropertyRead(node) {
  return ts.isPropertyAccessExpression(node)
    && ts.isIdentifier(node.expression)
    && node.expression.text === "message"
}

function isDynamicImport(expression) {
  return expression.kind === ts.SyntaxKind.ImportKeyword
}

function isRequireCall(expression) {
  return ts.isIdentifier(expression) && expression.text === "require"
}

function aliasesJsonParse(node) {
  if (!node.initializer) return false
  if (isJsonParse(node.initializer)) return true
  if (ts.isObjectBindingPattern(node.name) && ts.isIdentifier(node.initializer) && node.initializer.text === "JSON") {
    return node.name.elements.some((element) => bindingElementPropertyName(element) === "parse")
  }
  return false
}

function aliasesSdkImport(node, sdkNames) {
  if (!node.initializer) return false
  const root = sdkExpressionRoot(node.initializer)
  if (root !== undefined && sdkNames.has(root)) return true
  if (ts.isObjectBindingPattern(node.name) && ts.isIdentifier(node.initializer) && sdkNames.has(node.initializer.text)) return true
  return false
}

function bindingElementPropertyName(element) {
  const propertyName = element.propertyName ?? element.name
  if (ts.isIdentifier(propertyName) || ts.isStringLiteral(propertyName) || ts.isNumericLiteral(propertyName)) return propertyName.text
  return undefined
}

function declaredIdentifierName(node) {
  if ((ts.isFunctionDeclaration(node) || ts.isClassDeclaration(node)) && node.name) return node.name.text
  if ((ts.isVariableDeclaration(node) || ts.isParameter(node) || ts.isBindingElement(node)) && ts.isIdentifier(node.name)) return node.name.text
  return undefined
}

function importsName(statement, name) {
  if (!ts.isImportDeclaration(statement)) return false
  const clause = statement.importClause
  if (!clause) return false
  if (clause.name?.text === name) return true
  const bindings = clause.namedBindings
  if (!bindings || !ts.isNamedImports(bindings)) return false
  return bindings.elements.some((element) => element.name.text === name)
}

function containmentHelperLocalNames(file, source) {
  const names = new Set()
  for (const statement of source.statements) {
    if (!ts.isImportDeclaration(statement)) continue
    const specifier = statement.moduleSpecifier
    if (!specifier || !ts.isStringLiteral(specifier) || !specifier.text.startsWith(".")) continue
    if (layerOf(resolve(dirname(file), specifier.text)) !== "containment") continue
    const bindings = statement.importClause?.namedBindings
    if (!bindings || !ts.isNamedImports(bindings)) continue
    for (const element of bindings.elements) {
      const imported = element.propertyName?.text ?? element.name.text
      if (imported === "runContainedAgentTurn") names.add(element.name.text)
    }
  }
  return names
}


function isReadOnlyFsImport(statement) {
  if (!ts.isImportDeclaration(statement)) return false
  const clause = statement.importClause
  if (!clause || clause.name) return false
  const bindings = clause.namedBindings
  if (!bindings || !ts.isNamedImports(bindings)) return false
  return bindings.elements.every((element) => readOnlyFsImports.has((element.propertyName ?? element.name).text))
}

function sdkLocalNames(source) {
  const names = new Set()
  for (const statement of source.statements) {
    if (!ts.isImportDeclaration(statement)) continue
    const specifier = statement.moduleSpecifier
    if (!specifier || !ts.isStringLiteral(specifier) || specifier.text !== "@openai/codex-sdk") continue
    const clause = statement.importClause
    if (!clause) continue
    if (clause.name) names.add(clause.name.text)
    const bindings = clause.namedBindings
    if (!bindings) continue
    if (ts.isNamespaceImport(bindings)) names.add(bindings.name.text)
    if (ts.isNamedImports(bindings)) {
      for (const element of bindings.elements) names.add(element.name.text)
    }
  }
  return names
}

function journalStoreTypeNames(file, source) {
  const names = new Set()
  for (const statement of source.statements) {
    if (!ts.isImportDeclaration(statement)) continue
    const specifier = statement.moduleSpecifier
    if (!specifier || !ts.isStringLiteral(specifier) || !specifier.text.startsWith(".")) continue
    if (!isPortsImport(file, specifier.text)) continue
    const bindings = statement.importClause?.namedBindings
    if (!bindings || !ts.isNamedImports(bindings)) continue
    for (const element of bindings.elements) {
      const imported = element.propertyName?.text ?? element.name.text
      if (imported === "JournalStore") names.add(element.name.text)
    }
  }
  names.add("JournalStore")
  return names
}

function journalStoreNamespaces(file, source) {
  const names = new Set()
  for (const statement of source.statements) {
    if (!ts.isImportDeclaration(statement)) continue
    const specifier = statement.moduleSpecifier
    if (!specifier || !ts.isStringLiteral(specifier) || !specifier.text.startsWith(".")) continue
    if (!isPortsImport(file, specifier.text)) continue
    const bindings = statement.importClause?.namedBindings
    if (bindings && ts.isNamespaceImport(bindings)) names.add(bindings.name.text)
  }
  return names
}

function importedPortTypeNames(file, source, importedName) {
  const names = new Set([importedName])
  for (const statement of source.statements) {
    if (!ts.isImportDeclaration(statement)) continue
    const specifier = statement.moduleSpecifier
    if (!specifier || !ts.isStringLiteral(specifier) || !specifier.text.startsWith(".")) continue
    if (!isPortsImport(file, specifier.text)) continue
    const bindings = statement.importClause?.namedBindings
    if (!bindings || !ts.isNamedImports(bindings)) continue
    for (const element of bindings.elements) {
      const imported = element.propertyName?.text ?? element.name.text
      if (imported === importedName) names.add(element.name.text)
    }
  }
  return names
}

function hasProperty(node, name) {
  return node.properties.some((property) => {
    if (!ts.isPropertyAssignment(property) && !ts.isMethodDeclaration(property)) return false
    return propertyNameText(property.name) === name
  })
}

function hasClassMember(node, name) {
  return node.members.some((member) => {
    if (!ts.isMethodDeclaration(member) && !ts.isPropertyDeclaration(member)) return false
    return propertyNameText(member.name) === name
  })
}

function isPropertyNamed(node, name) {
  if (!ts.isPropertyAssignment(node) && !ts.isMethodDeclaration(node)) return false
  return propertyNameText(node.name) === name
}

function propertyNameText(name) {
  if (ts.isIdentifier(name) || ts.isStringLiteral(name) || ts.isNumericLiteral(name)) return name.text
  if (ts.isComputedPropertyName(name) && ts.isStringLiteral(name.expression)) return name.expression.text
  return undefined
}

function isPortsImport(file, specifier) {
  if (!specifier.startsWith(".")) return false
  if (layerOf(resolve(dirname(file), specifier)) === "ports") return true
  return specifier.includes("/src/ports/")
    || specifier.endsWith("/src/ports")
    || specifier.endsWith("/src/ports/index.ts")
}

function layerOfImportPath(targetPath) {
  const rel = relative(srcRoot, targetPath)
  const [head] = rel.split(sep)
  if (head === "cli.ts" || head === "index.ts") return "entry"
  return head
}

function fail(file, message) {
  violations.push(`${relative(appRoot, file)}: ${message}`)
}

function failAt(file, source, node, message) {
  const pos = source.getLineAndCharacterOfPosition(node.getStart(source))
  violations.push(`${relative(appRoot, file)}:${pos.line + 1}:${pos.character + 1}: ${message}`)
}

function failAtEmbedded(file, source, node, message) {
  const pos = source.getLineAndCharacterOfPosition(node.getStart(source))
  violations.push(`${relative(appRoot, file)}:embedded:${pos.line + 1}:${pos.character + 1}: ${message}`)
}

function layerOf(path) {
  return layerOfImportPath(path)
}
