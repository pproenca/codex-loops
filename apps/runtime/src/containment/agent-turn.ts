import type { ContainmentPolicy } from "../domain/contracts.ts"

export class ContainmentTimeoutError extends Error {
  constructor(message: string) {
    super(message)
    this.name = "ContainmentTimeoutError"
  }
}

export class ContainmentAbortedError extends Error {
  constructor(message: string) {
    super(message)
    this.name = "ContainmentAbortedError"
  }
}

export type ContainedTurnScope = {
  readonly signal: AbortSignal
  recordProgress(): void
}

export type ContainedTurnInput<T> = {
  readonly policy: ContainmentPolicy
  readonly callerSignal: AbortSignal
  readonly operation: (scope: ContainedTurnScope) => Promise<T>
}

export async function runContainedAgentTurn<T>(input: ContainedTurnInput<T>): Promise<T> {
  const controller = new AbortController()
  let failure: Error = new ContainmentAbortedError("agent turn aborted")

  const abortWith = (error: Error): void => {
    failure = error
    controller.abort(error)
  }

  const wallTimer = setTimeout(() => {
    abortWith(new ContainmentTimeoutError(`agent turn exceeded wall timeout ${input.policy.wallTimeoutMs}ms`))
  }, input.policy.wallTimeoutMs)

  let idleTimer = setTimeout(() => {
    abortWith(new ContainmentTimeoutError(`agent turn exceeded idle timeout ${input.policy.idleTimeoutMs}ms`))
  }, input.policy.idleTimeoutMs)

  const recordProgress = (): void => {
    clearTimeout(idleTimer)
    idleTimer = setTimeout(() => {
      abortWith(new ContainmentTimeoutError(`agent turn exceeded idle timeout ${input.policy.idleTimeoutMs}ms`))
    }, input.policy.idleTimeoutMs)
  }

  const abortFromCaller = (): void => {
    abortWith(new ContainmentAbortedError("agent turn aborted by caller"))
  }

  input.callerSignal.addEventListener("abort", abortFromCaller, { once: true })
  if (input.callerSignal.aborted) abortFromCaller()

  const aborted = new Promise<never>((_, reject) => {
    controller.signal.addEventListener("abort", () => reject(failure), { once: true })
  })

  try {
    return await Promise.race([
      input.operation({ signal: controller.signal, recordProgress }),
      aborted,
    ])
  } finally {
    clearTimeout(wallTimer)
    clearTimeout(idleTimer)
    input.callerSignal.removeEventListener("abort", abortFromCaller)
  }
}
