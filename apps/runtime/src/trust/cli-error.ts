import { ZodError } from "zod"

import { WorkflowValidationError } from "../domain/contracts.ts"
import type { Proven } from "../domain/brand.ts"
import type { JsonValue } from "../domain/json.ts"
import { proven } from "./proven.ts"

export type CliFailure = {
  readonly exitCode: number
  readonly message: string
  readonly payload: {
    readonly code: "usage" | "validation" | "runtime"
    readonly exitCode: number
    readonly message: string
    readonly details?: JsonValue | undefined
  }
}

export class CliUsageError extends Error {
  constructor(message: string) {
    super(message)
    this.name = "CliUsageError"
  }
}

export function parseCliFailure(error: unknown): Proven<CliFailure> {
  if (error instanceof WorkflowValidationError) {
    return proven({
      exitCode: 6,
      message: error.message,
      payload: {
        code: "validation",
        exitCode: 6,
        message: error.message,
        details: error.result as JsonValue,
      },
    })
  }
  if (error instanceof ZodError) {
    const message = error.issues.map((issue) => issue.message).join("; ")
    return proven({
      exitCode: 2,
      message,
      payload: {
        code: "usage",
        exitCode: 2,
        message,
        details: error.issues.map((issue) => ({ path: issue.path.join("."), message: issue.message })),
      },
    })
  }
  if (error instanceof CliUsageError) {
    return proven({
      exitCode: 2,
      message: error.message,
      payload: { code: "usage", exitCode: 2, message: error.message },
    })
  }
  if (error instanceof Error) {
    return proven({
      exitCode: 1,
      message: error.message,
      payload: { code: "runtime", exitCode: 1, message: error.message },
    })
  }
  return proven({
    exitCode: 1,
    message: String(error),
    payload: { code: "runtime", exitCode: 1, message: String(error) },
  })
}

export function parseErrorMessage(error: unknown): Proven<string> {
  if (error instanceof Error) return proven(error.message)
  return proven(String(error))
}
