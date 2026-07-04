import type { ProcessPort } from "../../ports/index.ts"

export class NodeProcessPort implements ProcessPort {
  pid(): number {
    return process.pid
  }

  cwd(): string {
    return process.cwd()
  }

  probePid(pid: number): void {
    process.kill(pid, 0)
  }
}
