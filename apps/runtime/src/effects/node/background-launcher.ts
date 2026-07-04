import { stat } from "node:fs/promises"
import { fileURLToPath } from "node:url"

import { spawnDetachedProcess } from "../../containment/background-process.ts"
import type { BackgroundProcessLauncher } from "../../ports/index.ts"

export async function isCliEntrypoint(input: { readonly moduleUrl: string; readonly argvEntry: string | undefined }): Promise<boolean> {
  if (input.argvEntry === undefined || input.argvEntry === "") return false
  const modulePath = fileURLToPath(input.moduleUrl)
  try {
    const moduleStat = await stat(modulePath)
    const entryStat = await stat(input.argvEntry)
    return moduleStat.dev === entryStat.dev && moduleStat.ino === entryStat.ino
  } catch {
    return modulePath === input.argvEntry
  }
}

export class NodeBackgroundProcessLauncher implements BackgroundProcessLauncher {
  readonly #cliEntryPath: string

  constructor(cliEntryPath: string) {
    this.#cliEntryPath = cliEntryPath
  }

  async launchResumeWorker(input: Parameters<BackgroundProcessLauncher["launchResumeWorker"]>[0]): ReturnType<BackgroundProcessLauncher["launchResumeWorker"]> {
    return spawnDetachedProcess({
      file: process.execPath,
      args: [this.#cliEntryPath, "resume", "--journal", input.journalPath, "--background-worker", "--quiet"],
      cwd: process.cwd(),
    })
  }

  async launchStatusServer(input: Parameters<BackgroundProcessLauncher["launchStatusServer"]>[0]): ReturnType<BackgroundProcessLauncher["launchStatusServer"]> {
    return spawnDetachedProcess({
      file: process.execPath,
      args: [this.#cliEntryPath, "serve", "--journal", input.journalPath, "--host", input.host, "--port", String(input.port), "--json"],
      cwd: process.cwd(),
    })
  }

  async terminate(input: Parameters<BackgroundProcessLauncher["terminate"]>[0]): ReturnType<BackgroundProcessLauncher["terminate"]> {
    try {
      process.kill(input.pid, "SIGTERM")
    } catch {
    }
  }

  wait(input: Parameters<BackgroundProcessLauncher["wait"]>[0]): ReturnType<BackgroundProcessLauncher["wait"]> {
    return new Promise((resolveWait) => {
      setTimeout(resolveWait, input.ms)
    })
  }
}
