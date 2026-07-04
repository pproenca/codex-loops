import { mkdir, open, readFile, rename, rm } from "node:fs/promises"
import { dirname } from "node:path"

import type { ServePortfileRecord } from "../domain/contracts.ts"
import type { ServePortfileStore } from "../ports/index.ts"

export class FileServePortfileStore implements ServePortfileStore {
  async writePortfile(record: ServePortfileRecord): Promise<void> {
    await mkdir(dirname(record.portfilePath), { recursive: true })
    const tempPath = `${record.portfilePath}.${record.pid}.tmp`
    const file = await open(tempPath, "w")
    try {
      const text = JSON.stringify({ url: record.url, pid: record.pid })
      await file.writeFile(`${text}\n`, "utf8")
      await file.sync()
    } finally {
      await file.close()
    }
    await rename(tempPath, record.portfilePath)
    await syncDirectory(dirname(record.portfilePath))
  }

  async readPortfile(portfilePath: string): Promise<string> {
    return readFile(portfilePath, "utf8")
  }

  async removePortfile(portfilePath: string): Promise<void> {
    await rm(portfilePath, { force: true })
  }
}

async function syncDirectory(path: string): Promise<void> {
  const dir = await open(path, "r")
  try {
    await dir.sync()
  } finally {
    await dir.close()
  }
}
