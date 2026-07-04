import { spawn } from "node:child_process"
import { cp, mkdir, rm, stat } from "node:fs/promises"
import { createRequire } from "node:module"
import { fileURLToPath } from "node:url"

import { build } from "esbuild"

const common = {
  bundle: true,
  platform: "node",
  format: "esm",
  target: "node24",
  // yaml and acorn bundle into dist; the codex SDK stays the only installed runtime dependency.
  external: ["@openai/codex-sdk"],
  // Bundled CJS deps (yaml) call require("process") etc.; in ESM output esbuild routes those
  // through a __require shim that throws "Dynamic require of ... is not supported" unless a real
  // require is in scope. Provide one via createRequire (esbuild keeps the shebang above the banner).
  banner: {
    js: 'import { createRequire as __agentLoopsCreateRequire } from "node:module"; const require = __agentLoopsCreateRequire(import.meta.url);',
  },
}

await rm("dist", { recursive: true, force: true })
await mkdir("dist", { recursive: true })

const uiProjectDirectory = fileURLToPath(new URL("../../status-ui/", import.meta.url))
try {
  const uiProject = await stat(uiProjectDirectory)
  if (!uiProject.isDirectory()) throw new Error("not a directory")
} catch (error) {
  throw new Error(`Codex Loops status UI package is required at ${uiProjectDirectory}: ${String(error)}`)
}

const uiBuildCode = await new Promise((resolve, reject) => {
  const child = spawn("pnpm", ["-C", uiProjectDirectory, "build"], { stdio: "inherit" })
  child.once("error", reject)
  child.once("exit", resolve)
})
if (uiBuildCode !== 0) process.exit(uiBuildCode ?? 1)

await Promise.all([
  build({
    ...common,
    entryPoints: ["src/cli.ts"],
    outfile: "dist/cli.js",
  }),
  build({
    ...common,
    entryPoints: ["src/index.ts"],
    outfile: "dist/index.js",
  }),
])

await cp(fileURLToPath(new URL("../../status-ui/dist/", import.meta.url)), "dist/status-ui", { recursive: true })

const tsc = createRequire(import.meta.url).resolve("typescript/bin/tsc")
const code = await new Promise((resolve, reject) => {
  const child = spawn(process.execPath, [tsc, "-p", "tsconfig.types.json"], { stdio: "inherit" })
  child.once("error", reject)
  child.once("exit", resolve)
})
if (code !== 0) process.exit(code ?? 1)
