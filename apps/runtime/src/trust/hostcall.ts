import { z } from "zod"

import type { Proven } from "../domain/brand.ts"
import type { HostAgentCall, HostLogCall, HostParallelCall, HostPhaseCall, HostPipelineCall, HostWorkflowCall, WorkflowChildMessage } from "../domain/contracts.ts"
import { jsonValueSchema } from "./json.ts"
import { proven } from "./proven.ts"

const hostAgentOptionsSchema = z.object({
  label: z.string().min(1).optional(),
  phase: z.string().min(1).optional(),
  schema: jsonValueSchema.optional(),
  model: z.string().min(1).optional(),
  agentType: z.string().min(1).optional(),
  isolation: z.enum(["read-only", "workspace-write", "worktree", "full-access"]).default("read-only"),
  risk: z.string().min(1).optional(),
}).strict()

const phaseArgsSchema = z.tuple([z.string().min(1)]).rest(z.never())
const logArgsSchema = z.tuple([z.string()]).rest(z.never())
const agentArgsSchema = z.tuple([z.string().min(1), hostAgentOptionsSchema.default({ isolation: "read-only" })]).rest(z.never())
const workflowRefSchema = z.union([
  z.string().min(1).transform((value) => ({ t: "named" as const, value })),
  z.object({ scriptPath: z.string().min(1) }).strict().transform((value) => ({ t: "script_path" as const, scriptPath: value.scriptPath })),
])
const workflowArgsSchema = z.tuple([workflowRefSchema, jsonValueSchema.optional()]).rest(z.never())
const parallelArgsSchema = z.tuple([z.number().int().nonnegative()]).rest(z.never())
const pipelineArgsSchema = z.tuple([z.number().int().nonnegative(), z.number().int().nonnegative()]).rest(z.never())

const childHostcallEnvelopeSchema = z.object({
  t: z.literal("hostcall"),
  id: z.number().int().positive(),
  op: z.enum(["phase", "log", "agent", "workflow", "parallel", "pipeline"]),
  args: z.array(z.unknown()),
}).strict()

const childDoneEnvelopeSchema = z.object({
  t: z.literal("done"),
  value: jsonValueSchema,
}).strict()

const childFailedEnvelopeSchema = z.object({
  t: z.literal("failed"),
  message: z.string(),
}).strict()

export function parsePhaseHostcall(args: readonly unknown[]): Proven<HostPhaseCall> {
  const parsed = phaseArgsSchema.parse(args)
  return proven({ title: parsed[0] })
}

export function parseLogHostcall(args: readonly unknown[]): Proven<HostLogCall> {
  const parsed = logArgsSchema.parse(args)
  return proven({ message: parsed[0] })
}

export function parseConsoleHostcall(args: readonly unknown[]): Proven<HostLogCall> {
  return proven({ message: args.map((entry) => String(entry)).join(" ") })
}

export function parseAgentHostcall(args: readonly unknown[]): Proven<HostAgentCall> {
  const parsed = agentArgsSchema.parse(args)
  return proven({ prompt: parsed[0], options: parsed[1] })
}

export function parseWorkflowHostcall(args: readonly unknown[]): Proven<HostWorkflowCall> {
  const parsed = workflowArgsSchema.parse(args)
  return proven({ ref: parsed[0], args: parsed[1] === undefined ? null : parsed[1] })
}

export function parseParallelHostcall(args: readonly unknown[]): Proven<HostParallelCall> {
  const parsed = parallelArgsSchema.parse(args)
  return proven({ itemCount: parsed[0] })
}

export function parsePipelineHostcall(args: readonly unknown[]): Proven<HostPipelineCall> {
  const parsed = pipelineArgsSchema.parse(args)
  return proven({ itemCount: parsed[0], stageCount: parsed[1] })
}

export function parseWorkflowChildLine(line: string): Proven<WorkflowChildMessage> {
  const raw = JSON.parse(line)
  const done = childDoneEnvelopeSchema.safeParse(raw)
  if (done.success) return proven({ t: "done", value: done.data.value })
  const failed = childFailedEnvelopeSchema.safeParse(raw)
  if (failed.success) return proven({ t: "failed", message: failed.data.message })
  const envelope = childHostcallEnvelopeSchema.parse(raw)
  switch (envelope.op) {
    case "phase":
      return proven({ t: "hostcall", id: envelope.id, op: "phase", call: parsePhaseHostcall(envelope.args) })
    case "log":
      return proven({ t: "hostcall", id: envelope.id, op: "log", call: parseLogHostcall(envelope.args) })
    case "agent":
      return proven({ t: "hostcall", id: envelope.id, op: "agent", call: parseAgentHostcall(envelope.args) })
    case "workflow":
      return proven({ t: "hostcall", id: envelope.id, op: "workflow", call: parseWorkflowHostcall(envelope.args) })
    case "parallel":
      return proven({ t: "hostcall", id: envelope.id, op: "parallel", call: parseParallelHostcall(envelope.args) })
    case "pipeline":
      return proven({ t: "hostcall", id: envelope.id, op: "pipeline", call: parsePipelineHostcall(envelope.args) })
  }
}
