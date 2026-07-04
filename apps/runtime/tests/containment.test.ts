import assert from "node:assert/strict"
import { setTimeout as sleep } from "node:timers/promises"
import { test } from "node:test"

import { ContainmentAbortedError, ContainmentTimeoutError, runContainedAgentTurn } from "../src/containment/agent-turn.ts"
import { BoundedProcessOutputError, BoundedProcessTimeoutError, execFileBounded } from "../src/containment/process.ts"

const policy = {
  wallTimeoutMs: 50,
  idleTimeoutMs: 25,
}

test("contained agent turn returns completed operation result", async () => {
  const caller = new AbortController()
  const result = await runContainedAgentTurn({
    policy,
    callerSignal: caller.signal,
    operation: async () => "done",
  })

  assert.equal(result, "done")
})

test("contained agent turn enforces wall timeout", async () => {
  const caller = new AbortController()

  await assert.rejects(
    () => runContainedAgentTurn({
      policy: { wallTimeoutMs: 5, idleTimeoutMs: 100 },
      callerSignal: caller.signal,
      operation: async () => {
        await sleep(30)
        return "late"
      },
    }),
    ContainmentTimeoutError,
  )
})

test("contained agent turn enforces idle timeout", async () => {
  const caller = new AbortController()

  await assert.rejects(
    () => runContainedAgentTurn({
      policy: { wallTimeoutMs: 100, idleTimeoutMs: 5 },
      callerSignal: caller.signal,
      operation: async () => {
        await sleep(30)
        return "late"
      },
    }),
    ContainmentTimeoutError,
  )
})

test("contained agent turn respects caller abort", async () => {
  const caller = new AbortController()
  const promise = runContainedAgentTurn({
    policy,
    callerSignal: caller.signal,
    operation: async () => {
      await sleep(30)
      return "late"
    },
  })

  caller.abort()
  await assert.rejects(() => promise, ContainmentAbortedError)
})

test("bounded execFile captures output and exit status", async () => {
  const result = await execFileBounded({
    file: process.execPath,
    args: ["-e", "process.stdout.write('ok'); process.stderr.write('warn')"],
    policy: { timeoutMs: 1_000, maxStdoutBytes: 32, maxStderrBytes: 32 },
  })

  assert.equal(result.exitCode, 0)
  assert.equal(result.signal, null)
  assert.equal(result.stdout, "ok")
  assert.equal(result.stderr, "warn")
})

test("bounded execFile enforces timeout", async () => {
  await assert.rejects(
    () => execFileBounded({
      file: process.execPath,
      args: ["-e", "setTimeout(() => {}, 1000)"],
      policy: { timeoutMs: 10, maxStdoutBytes: 32, maxStderrBytes: 32 },
    }),
    BoundedProcessTimeoutError,
  )
})

test("bounded execFile enforces output limits", async () => {
  await assert.rejects(
    () => execFileBounded({
      file: process.execPath,
      args: ["-e", "process.stdout.write('x'.repeat(100))"],
      policy: { timeoutMs: 1_000, maxStdoutBytes: 32, maxStderrBytes: 32 },
    }),
    BoundedProcessOutputError,
  )
})
