import { spawn } from "node:child_process"

export type DetachedProcessInput = {
  readonly file: string
  readonly args: readonly string[]
  readonly cwd: string
}

export type DetachedProcessResult = {
  readonly pid: number
}

export function spawnDetachedProcess(input: DetachedProcessInput): DetachedProcessResult {
  const child = spawn(input.file, [...input.args], {
    cwd: input.cwd,
    detached: true,
    stdio: "ignore",
    env: process.env,
  })
  child.unref()
  return { pid: child.pid === undefined ? 0 : child.pid }
}
