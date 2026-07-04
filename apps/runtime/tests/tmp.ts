import { mkdir, mkdtemp } from "node:fs/promises"
import { join } from "node:path"
import { fileURLToPath } from "node:url"

const testTmpRoot = fileURLToPath(new URL("../.tmp/tests/", import.meta.url))

export async function makeTempDir(prefix: string): Promise<string> {
  await mkdir(testTmpRoot, { recursive: true })
  return mkdtemp(join(testTmpRoot, prefix))
}
