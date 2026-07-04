import { spawn } from "node:child_process"

import type { WorkflowChildExecutionPolicy } from "../domain/contracts.ts"
import { BoundedProcessLaunchError, BoundedProcessOutputError, BoundedProcessTimeoutError } from "./process.ts"

export type WorkflowChildProtocolDecision =
  | { readonly t: "respond"; readonly line: string }
  | { readonly t: "complete"; readonly line: string }

export type WorkflowChildProcessInput = {
  readonly initLine: string
  readonly policy: WorkflowChildExecutionPolicy
  readonly onLine: (line: string) => Promise<WorkflowChildProtocolDecision>
}

export function runWorkflowChildProcess(input: WorkflowChildProcessInput): Promise<string> {
  return new Promise((resolve, reject) => {
    const child = spawn(process.execPath, [
      "--permission",
      "--disable-proto=throw",
      "--input-type=module",
      "--eval",
      WORKFLOW_CHILD_SOURCE,
    ], {
      stdio: ["pipe", "pipe", "pipe"],
      env: {},
    })
    let stdoutText = ""
    let stderrText = ""
    let stdoutBytes = 0
    let stderrBytes = 0
    let settled = false
    let finalLine: string | undefined
    let handling = Promise.resolve()

    const finish = (done: () => void): void => {
      if (settled) return
      settled = true
      clearTimeout(timer)
      done()
    }

    const fail = (error: Error): void => {
      finish(() => {
        child.kill("SIGKILL")
        reject(error)
      })
    }

    const enqueue = (line: string): void => {
      if (line.length === 0) return
      handling = handling.then(async () => {
        const decision = await input.onLine(line)
        switch (decision.t) {
          case "respond":
            child.stdin.write(`${decision.line}\n`)
            return
          case "complete":
            finalLine = decision.line
            return
        }
      }).catch((error) => {
        fail(new BoundedProcessLaunchError(String(error)))
      })
    }

    const drainStdoutLines = (): void => {
      let newline = stdoutText.indexOf("\n")
      while (newline >= 0) {
        const line = stdoutText.slice(0, newline)
        stdoutText = stdoutText.slice(newline + 1)
        enqueue(line)
        newline = stdoutText.indexOf("\n")
      }
    }

    const timer = setTimeout(() => {
      fail(new BoundedProcessTimeoutError(`workflow child exceeded timeout ${input.policy.wallTimeoutMs}ms`))
    }, input.policy.wallTimeoutMs)

    child.stdout.on("data", (chunk: Buffer) => {
      stdoutBytes += chunk.length
      if (stdoutBytes > input.policy.maxStdoutBytes) {
        fail(new BoundedProcessOutputError(`workflow child stdout exceeded ${input.policy.maxStdoutBytes} bytes`))
        return
      }
      stdoutText += chunk.toString("utf8")
      drainStdoutLines()
    })

    child.stderr.on("data", (chunk: Buffer) => {
      stderrBytes += chunk.length
      if (stderrBytes > input.policy.maxStderrBytes) {
        fail(new BoundedProcessOutputError(`workflow child stderr exceeded ${input.policy.maxStderrBytes} bytes`))
        return
      }
      stderrText += chunk.toString("utf8")
    })

    child.on("error", (error: Error) => {
      fail(new BoundedProcessLaunchError(error.message))
    })

    child.on("close", (exitCode, signal) => {
      if (stdoutText.length > 0) {
        enqueue(stdoutText)
        stdoutText = ""
      }
      finish(() => {
        handling.then(() => {
          if (finalLine === undefined) {
            if (exitCode !== 0) {
              reject(new BoundedProcessLaunchError(`workflow child exited with ${exitCode === null ? signal : exitCode}: ${stderrText}`))
              return
            }
            reject(new BoundedProcessLaunchError("workflow child exited without a terminal message"))
            return
          }
          resolve(finalLine)
        }).catch((error) => {
          reject(new BoundedProcessLaunchError(String(error)))
        })
      })
    })

    child.stdin.write(`${input.initLine}\n`)
  })
}

const WORKFLOW_CHILD_SOURCE = String.raw`
import { createInterface } from "node:readline";

const rl = createInterface({ input: process.stdin, crlfDelay: Infinity });
const AsyncFunction = async function () {}.constructor;
const pending = new Map();
let initialized = false;
let nextId = 1;
let budgetState = { total: null, spent: 0 };

const send = (message) => {
  process.stdout.write(JSON.stringify(message) + "\n");
};

const fail = (error) => {
  const message = error && typeof error.message === "string" ? error.message : String(error);
  send({ t: "failed", message });
  process.exitCode = 1;
  rl.close();
};

const jsonValue = (value) => {
  if (value === undefined) return null;
  return JSON.parse(JSON.stringify(value));
};

const call = (op, args) => {
  const id = nextId;
  nextId += 1;
  return new Promise((resolve, reject) => {
    pending.set(id, { resolve, reject });
    send({ t: "hostcall", id, op, args });
  });
};

const controlError = (message) => {
  const error = new Error(message);
  error.name = "WorkflowChildError";
  return error;
};

const makeRuntime = () => {
  const makeBudget = () => Object.freeze({
    get total() { return budgetState.total; },
    spent: () => budgetState.spent,
    remaining: () => budgetState.total == null ? Infinity : Math.max(0, budgetState.total - budgetState.spent),
  });
  const phase = (title) => call("phase", [title]);
  const log = (message) => call("log", [message]);
  const agent = (prompt, options) => call("agent", [prompt, options === undefined ? {} : options]);
  const workflow = (ref, args) => call("workflow", [ref, args === undefined ? null : args]);
  const parallel = async (tasks) => {
    await call("parallel", [tasks.length]);
    const results = [];
    for (let index = 0; index < tasks.length; index += 1) results.push(await tasks[index]());
    return results;
  };
  const pipeline = async (items, ...stages) => {
    await call("pipeline", [items.length, stages.length]);
    let current = items;
    for (const stage of stages) {
      const next = [];
      for (let index = 0; index < current.length; index += 1) next.push(await stage(current[index], current[index], index));
      current = next;
    }
    return current;
  };
  const logConsole = (...args) => log(args.map((entry) => String(entry)).join(" "));
  const DateShim = function Date() {
    throw controlError("Date is not available in workflow scripts");
  };
  DateShim.now = () => {
    throw controlError("Date is not available in workflow scripts");
  };
  const math = Object.create(Math);
  math.random = () => {
    throw controlError("Math.random is not available in workflow scripts");
  };
  return {
    phase,
    budget: makeBudget(),
    log,
    agent,
    workflow,
    parallel,
    pipeline,
    console: Object.freeze({ log: logConsole, warn: logConsole, error: logConsole }),
    DateShim,
    math,
  };
};

const runWorkflow = async (init) => {
  if (init.budget && typeof init.budget === "object") {
    budgetState = {
      total: typeof init.budget.total === "number" ? init.budget.total : null,
      spent: typeof init.budget.spent === "number" ? init.budget.spent : 0,
    };
  }
  const runtime = makeRuntime();
  const rewritten = init.source.replace(/\bexport(\s+const\s+meta\s*=)/, "$1");
  const body = "\"use strict\";\nconst __workflow_main = async () => {\n" + rewritten + "\n};\nreturn await __workflow_main();\n";
  const fn = new AsyncFunction(
    "args",
    "budget",
    "phase",
    "log",
    "agent",
    "workflow",
    "parallel",
    "pipeline",
    "console",
    "Date",
    "Math",
    "process",
    "Buffer",
    "globalThis",
    "fetch",
    "WebSocket",
    "EventSource",
    "setTimeout",
    "setInterval",
    "require",
    "Function",
    "Reflect",
    "crypto",
    "performance",
    "Intl",
    body,
  );
  const result = await fn(
    init.args,
    runtime.budget,
    runtime.phase,
    runtime.log,
    runtime.agent,
    runtime.workflow,
    runtime.parallel,
    runtime.pipeline,
    runtime.console,
    runtime.DateShim,
    runtime.math,
    undefined,
    undefined,
    undefined,
    undefined,
    undefined,
    undefined,
    undefined,
    undefined,
    undefined,
    undefined,
    undefined,
    undefined,
    undefined,
    undefined,
  );
  send({ t: "done", value: jsonValue(result) });
  rl.close();
};

const parseResponseLine = (line) => {
  const first = line.indexOf("\t");
  const second = line.indexOf("\t", first + 1);
  const id = Number(line.slice(0, first));
  const ok = line.slice(first + 1, second) === "1";
  const payload = JSON.parse(line.slice(second + 1));
  const isEnvelope = payload && typeof payload === "object" && ("value" in payload || "budget" in payload);
  if (isEnvelope && payload.budget && typeof payload.budget === "object") {
    budgetState = {
      total: typeof payload.budget.total === "number" ? payload.budget.total : null,
      spent: typeof payload.budget.spent === "number" ? payload.budget.spent : 0,
    };
  }
  return { id, ok, payload: isEnvelope ? payload.value : payload };
};

rl.on("line", (line) => {
  try {
    if (!initialized) {
      initialized = true;
      runWorkflow(JSON.parse(line)).catch(fail);
      return;
    }
    const response = parseResponseLine(line);
    const waiting = pending.get(response.id);
    if (!waiting) return;
    pending.delete(response.id);
    if (response.ok) {
      waiting.resolve(response.payload === undefined ? null : response.payload);
      return;
    }
    waiting.reject(controlError(String(response.payload)));
  } catch (error) {
    fail(error);
  }
});
`
