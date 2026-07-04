import type { Proven } from "../domain/brand.ts"

export function proven<T>(value: T): Proven<T> {
  return value as unknown as Proven<T>
}
