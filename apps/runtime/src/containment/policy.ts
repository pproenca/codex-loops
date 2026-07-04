import type { ContainmentPolicy } from "../domain/contracts.ts"

export function describeContainmentPolicy(policy: ContainmentPolicy): string {
  return `wall=${policy.wallTimeoutMs}ms idle=${policy.idleTimeoutMs}ms`
}
