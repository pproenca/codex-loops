import { readdir, stat } from "node:fs/promises"
import { join } from "node:path"

import type { JournalFileCandidate } from "../../domain/contracts.ts"
import type { JournalDirectoryPort } from "../../ports/index.ts"

export class FileJournalDirectory implements JournalDirectoryPort {
  async listJournalFiles(root: string): Promise<readonly JournalFileCandidate[]> {
    const files = await listFiles(root)
    return files.sort((a, b) => a.path.localeCompare(b.path))
  }
}

async function listFiles(root: string): Promise<JournalFileCandidate[]> {
  const entries = await readdir(root, { withFileTypes: true })
  const files: JournalFileCandidate[] = []
  for (const entry of entries) {
    const path = join(root, entry.name)
    if (entry.isDirectory()) {
      files.push(...await listFiles(path))
    } else if (entry.isFile() && (entry.name.endsWith(".jsonl") || entry.name.endsWith(".json"))) {
      const candidate = await candidateFor(path)
      if (candidate.t === "present") files.push({ path, updatedAt: candidate.updatedAt })
    }
  }
  return files
}

async function candidateFor(path: string): Promise<{ readonly t: "present"; readonly updatedAt: string } | { readonly t: "missing" }> {
  return { t: "present", updatedAt: (await stat(path)).mtime.toISOString() }
}
