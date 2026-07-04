import { z } from "zod"

import type { Proven } from "../domain/brand.ts"
import type { ProviderEvent } from "../domain/contracts.ts"
import { proven } from "./proven.ts"

const sdkBaseEventSchema = z.object({ type: z.string().min(1) }).passthrough()
const nonNegativeIntSchema = z.number().int().nonnegative()

const threadStartedSchema = z.object({
  type: z.literal("thread.started"),
  thread_id: z.string().min(1),
}).strict()

const agentMessageItemSchema = z.object({
  id: z.string().min(1),
  type: z.literal("agent_message"),
  text: z.string(),
})

const mcpToolCallItemSchema = z.object({
  id: z.string().min(1),
  type: z.literal("mcp_tool_call"),
  server: z.string().min(1),
  tool: z.string().min(1),
  status: z.string().min(1),
})

const commandExecutionItemSchema = z.object({
  id: z.string().min(1),
  type: z.literal("command_execution"),
  command: z.string().min(1),
  status: z.string().min(1),
  exit_code: nonNegativeIntSchema.optional(),
})

const fileUpdateChangeSchema = z.object({
  path: z.string().min(1),
  kind: z.string().min(1),
})

const fileChangeItemSchema = z.object({
  id: z.string().min(1),
  type: z.literal("file_change"),
  changes: z.tuple([fileUpdateChangeSchema]).rest(fileUpdateChangeSchema),
  status: z.string().min(1),
})

const itemCompletedSchema = z.object({
  type: z.literal("item.completed"),
  item: z.discriminatedUnion("type", [
    agentMessageItemSchema,
    mcpToolCallItemSchema,
    commandExecutionItemSchema,
    fileChangeItemSchema,
  ]),
}).strict()

const turnCompletedSchema = z.object({
  type: z.literal("turn.completed"),
  usage: z.object({
    input_tokens: nonNegativeIntSchema,
    cached_input_tokens: nonNegativeIntSchema,
    output_tokens: nonNegativeIntSchema,
    reasoning_output_tokens: nonNegativeIntSchema,
  }).strict(),
}).strict()

const turnFailedSchema = z.object({
  type: z.literal("turn.failed"),
  error: z.object({ message: z.string().min(1) }).strict(),
}).strict()

const errorEventSchema = z.object({
  type: z.literal("error"),
  message: z.string().min(1),
}).strict()

export function parseProviderStreamEvent(input: unknown): Proven<ProviderEvent> {
  const base = sdkBaseEventSchema.parse(input)
  switch (base.type) {
    case "thread.started": {
      const parsed = threadStartedSchema.parse(base)
      return proven<ProviderEvent>({ t: "thread_bound", threadId: parsed.thread_id })
    }
    case "item.completed": {
      const parsed = itemCompletedSchema.parse(base)
      switch (parsed.item.type) {
        case "agent_message":
          return proven<ProviderEvent>({ t: "message_observed", text: parsed.item.text })
        case "mcp_tool_call":
          return proven<ProviderEvent>({
            t: "tool_observed",
            name: parsed.item.tool,
            summary: `server=${parsed.item.server} status=${parsed.item.status}`,
          })
        case "command_execution":
          return proven<ProviderEvent>({
            t: "tool_observed",
            name: "command_execution",
            summary: parsed.item.exit_code === undefined
              ? `${parsed.item.command} status=${parsed.item.status}`
              : `${parsed.item.command} status=${parsed.item.status} exit=${parsed.item.exit_code}`,
          })
        case "file_change": {
          return proven<ProviderEvent>({
            t: "file_mutations_observed",
            files: parsed.item.changes.map((change) => ({ path: change.path, operation: change.kind })),
          })
        }
      }
    }
    case "turn.completed": {
      const parsed = turnCompletedSchema.parse(base)
      return proven<ProviderEvent>({
        t: "usage_observed",
        inputTokens: parsed.usage.input_tokens,
        outputTokens: parsed.usage.output_tokens,
      })
    }
    case "turn.failed": {
      const parsed = turnFailedSchema.parse(base)
      return proven<ProviderEvent>({ t: "provider_failed", message: parsed.error.message })
    }
    case "error": {
      const parsed = errorEventSchema.parse(base)
      return proven<ProviderEvent>({ t: "provider_failed", message: parsed.message })
    }
    default:
      return proven<ProviderEvent>({ t: "unknown_telemetry", sdkType: base.type })
  }
}
