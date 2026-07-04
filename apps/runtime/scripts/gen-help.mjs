#!/usr/bin/env node
// Renders the CLI COMMANDS table (src/cli.ts is the single source) as the markdown command block
// for the four doc sites, wrapped in <!-- gen:commands --> / <!-- /gen:commands --> markers.
//
//   node scripts/gen-help.mjs            print the generated block to stdout
//   node scripts/gen-help.mjs --check    verify every doc site's block matches (repo CI)
//   node scripts/gen-help.mjs --write    rewrite the block in place at every doc site
import { readFile, writeFile } from "node:fs/promises"
import { resolve } from "node:path"
import { fileURLToPath } from "node:url"

const { renderCommandsBlock } = await import(new URL("../src/cli.ts", import.meta.url))

const repoRoot = resolve(fileURLToPath(new URL("../../..", import.meta.url)))
const DOC_SITES = [
  "apps/runtime/README.md",
  "plugins/codex-loops/README.md",
  "plugins/codex-loops/SPEC.md",
  "plugins/codex-loops/skills/codex-loops/SKILL.md",
]

const BEGIN = "<!-- gen:commands -->"
const END = "<!-- /gen:commands -->"
const generated = renderCommandsBlock()
const wrapped = `${BEGIN}\n${generated}\n${END}`

const mode = process.argv[2] ?? "--print"

if (mode === "--print") {
  process.stdout.write(`${wrapped}\n`)
  process.exit(0)
}

if (mode !== "--check" && mode !== "--write") {
  process.stderr.write(`gen-help: unknown mode ${mode} (expected --check or --write)\n`)
  process.exit(2)
}

function splitOnMarkers(text) {
  const begin = text.indexOf(BEGIN)
  const end = text.indexOf(END)
  if (begin < 0 || end < 0 || end < begin) return undefined
  return {
    before: text.slice(0, begin + BEGIN.length),
    inner: text.slice(begin + BEGIN.length, end).replace(/^\n|\n$/g, ""),
    after: text.slice(end),
  }
}

let failures = 0
for (const site of DOC_SITES) {
  const path = resolve(repoRoot, site)
  let text
  try {
    text = await readFile(path, "utf8")
  } catch (error) {
    process.stderr.write(`gen-help: ${site}: unreadable (${error.message})\n`)
    failures += 1
    continue
  }
  const parts = splitOnMarkers(text)
  if (!parts) {
    process.stderr.write(`gen-help: ${site}: missing ${BEGIN} / ${END} markers\n`)
    failures += 1
    continue
  }
  if (mode === "--check") {
    if (parts.inner !== generated) {
      process.stderr.write(`gen-help: ${site}: command block is out of date (run: node apps/runtime/scripts/gen-help.mjs --write)\n`)
      failures += 1
    }
    continue
  }
  if (parts.inner !== generated) {
    await writeFile(path, `${parts.before}\n${generated}\n${parts.after}`, "utf8")
    process.stderr.write(`gen-help: ${site}: updated\n`)
  }
}

if (failures > 0) process.exit(1)
