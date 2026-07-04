import type { Proven } from "../domain/brand.ts"
import type { GitWorktreeFacts } from "../domain/contracts.ts"
import type { GitPort } from "../ports/index.ts"
import { parseGitRootProbe, parseGitStatusProbe, parseGitWorktreeFacts } from "../trust/git.ts"

export async function inspectGitWorktree(cwd: string, git: GitPort): Promise<Proven<GitWorktreeFacts>> {
  const root = parseGitRootProbe(await git.probeRoot(cwd))
  switch (root.t) {
    case "not_repo":
      return parseGitWorktreeFacts({ t: "not_repo" })
    case "repo":
      {
        const status = parseGitStatusProbe(await git.probeStatus(root.root))
        return parseGitWorktreeFacts({ t: "repo", root: root.root, dirty: status.dirty })
      }
  }
}
