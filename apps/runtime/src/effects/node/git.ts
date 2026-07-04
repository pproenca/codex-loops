import { execFileBounded, type BoundedExecFilePolicy } from "../../containment/process.ts"
import type { GitPort } from "../../ports/index.ts"

export class NodeGitPort implements GitPort {
  readonly #policy: BoundedExecFilePolicy

  constructor(policy: BoundedExecFilePolicy) {
    this.#policy = policy
  }

  async probeRoot(cwd: string): ReturnType<GitPort["probeRoot"]> {
    return execFileBounded({
      file: "git",
      args: ["rev-parse", "--show-toplevel"],
      cwd,
      policy: this.#policy,
    })
  }

  async probeStatus(cwd: string): ReturnType<GitPort["probeStatus"]> {
    return execFileBounded({
      file: "git",
      args: ["status", "--porcelain=v1", "-z"],
      cwd,
      policy: this.#policy,
    })
  }
}
