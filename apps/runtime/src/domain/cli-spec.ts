import type { CommandName } from "./contracts.ts"

export type CliFlagType = "boolean" | "string"

export type CliCommandSpec = {
  readonly name: CommandName
  readonly summary: string
  readonly usage: readonly string[]
  readonly flags: readonly string[]
  readonly maxPositionals: number
}
