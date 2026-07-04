import { z } from "zod"

import type { Proven } from "../domain/brand.ts"
import type { ContainmentPolicy, RunnerHeartbeatPolicy, WorkflowChildExecutionPolicy } from "../domain/contracts.ts"
import { proven } from "./proven.ts"

const containmentPolicySchema = z.object({
  wallTimeoutMs: z.number().int().positive().default(30 * 60_000),
  idleTimeoutMs: z.number().int().positive().default(5 * 60_000),
}).strict()

const workflowChildExecutionPolicySchema = containmentPolicySchema.extend({
  maxStdoutBytes: z.number().int().positive().default(1_000_000),
  maxStderrBytes: z.number().int().positive().default(100_000),
}).strict()

const runnerHeartbeatPolicySchema = z.object({
  intervalMs: z.number().int().positive().default(10_000),
}).strict()

export function parseContainmentPolicy(input: unknown): Proven<ContainmentPolicy> {
  return proven(containmentPolicySchema.parse(input))
}

export function parseWorkflowChildExecutionPolicy(input: unknown): Proven<WorkflowChildExecutionPolicy> {
  return proven(workflowChildExecutionPolicySchema.parse(input))
}

export function parseRunnerHeartbeatPolicy(input: unknown): Proven<RunnerHeartbeatPolicy> {
  return proven(runnerHeartbeatPolicySchema.parse(input))
}
