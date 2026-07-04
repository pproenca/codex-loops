import { spawn } from "node:child_process"

import type { ProcessExecutionResult } from "../domain/contracts.ts"

export type BoundedExecFilePolicy = {
  readonly timeoutMs: number
  readonly maxStdoutBytes: number
  readonly maxStderrBytes: number
}

export type BoundedExecFileInput = {
  readonly file: string
  readonly args: readonly string[]
  readonly cwd?: string
  readonly env?: Readonly<Record<string, string>>
  readonly policy: BoundedExecFilePolicy
}

export type BoundedExecFileResult = ProcessExecutionResult

export class BoundedProcessTimeoutError extends Error {
  constructor(message: string) {
    super(message)
    this.name = "BoundedProcessTimeoutError"
  }
}

export class BoundedProcessOutputError extends Error {
  constructor(message: string) {
    super(message)
    this.name = "BoundedProcessOutputError"
  }
}

export class BoundedProcessLaunchError extends Error {
  constructor(message: string) {
    super(message)
    this.name = "BoundedProcessLaunchError"
  }
}

export function execFileBounded(input: BoundedExecFileInput): Promise<BoundedExecFileResult> {
  return new Promise((resolve, reject) => {
    const child = spawn(input.file, [...input.args], {
      stdio: ["ignore", "pipe", "pipe"],
      ...(input.cwd === undefined ? {} : { cwd: input.cwd }),
      ...(input.env === undefined ? {} : { env: input.env }),
    })
    const stdout: Buffer[] = []
    const stderr: Buffer[] = []
    let stdoutBytes = 0
    let stderrBytes = 0
    let settled = false

    const finish = (done: () => void): void => {
      if (settled) return
      settled = true
      clearTimeout(timer)
      done()
    }

    const fail = (error: Error): void => {
      finish(() => {
        child.kill("SIGKILL")
        reject(error)
      })
    }

    const timer = setTimeout(() => {
      fail(new BoundedProcessTimeoutError(`process exceeded timeout ${input.policy.timeoutMs}ms: ${input.file}`))
    }, input.policy.timeoutMs)

    child.stdout.on("data", (chunk: Buffer) => {
      stdoutBytes += chunk.length
      if (stdoutBytes > input.policy.maxStdoutBytes) {
        fail(new BoundedProcessOutputError(`process stdout exceeded ${input.policy.maxStdoutBytes} bytes: ${input.file}`))
        return
      }
      stdout.push(chunk)
    })

    child.stderr.on("data", (chunk: Buffer) => {
      stderrBytes += chunk.length
      if (stderrBytes > input.policy.maxStderrBytes) {
        fail(new BoundedProcessOutputError(`process stderr exceeded ${input.policy.maxStderrBytes} bytes: ${input.file}`))
        return
      }
      stderr.push(chunk)
    })

    child.on("error", (error: Error) => {
      finish(() => {
        reject(new BoundedProcessLaunchError(error.message))
      })
    })

    child.on("close", (exitCode, signal) => {
      finish(() => {
        resolve({
          exitCode,
          signal,
          stdout: Buffer.concat(stdout).toString("utf8"),
          stderr: Buffer.concat(stderr).toString("utf8"),
        })
      })
    })
  })
}
