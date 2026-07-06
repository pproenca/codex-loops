import { z } from "zod"

const nodeSchema = z.object({
  id: z.string().optional(),
  label: z.string().optional(),
  state: z.string().optional(),
  model: z.string().optional(),
  tokens: z.number().optional(),
  toolCalls: z.number().optional(),
  promptFull: z.string().optional(),
  promptPreview: z.string().optional(),
  lastToolSummary: z.string().optional(),
  result: z.unknown().optional(),
  error: z.unknown().optional(),
}).passthrough()

const phaseSchema = z.object({
  title: z.string().optional(),
  status: z.string().optional(),
  nodes: z.array(nodeSchema).default([]),
}).passthrough()

export const statusPayloadSchema = z.object({
  runId: z.string().optional(),
  databasePath: z.string().optional(),
  status: z.object({
    runId: z.string().optional(),
    workflowName: z.string().optional(),
    status: z.string().optional(),
    phases: z.array(phaseSchema).default([]),
  }).passthrough(),
}).passthrough()

export type StatusPayload = z.infer<typeof statusPayloadSchema>
export type StatusPhase = StatusPayload["status"]["phases"][number]
export type StatusNode = StatusPhase["nodes"][number]

export function parseStatusPayload(value: unknown): StatusPayload {
  return statusPayloadSchema.parse(value)
}
