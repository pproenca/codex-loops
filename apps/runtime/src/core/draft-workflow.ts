import type { DraftCommandRequest, DraftWorkflowPlan } from "../domain/contracts.ts"

export function planDraftWorkflow(input: {
  readonly request: DraftCommandRequest
  readonly cwd: string
}): DraftWorkflowPlan {
  const workflowName = slugify(input.request.name === undefined ? input.request.goal : input.request.name)
  const scriptPath = draftPath({ cwd: input.cwd, workflowName, output: input.request.output })
  const script = draftScript({ workflowName, goal: input.request.goal })
  return {
    workflowName,
    scriptPath,
    script,
    nextSteps: [`agent-loops test ${workflowName}`, `agent-loops workflow ${workflowName} --approved`],
  }
}

function draftPath(input: { readonly cwd: string; readonly workflowName: string; readonly output?: string | undefined }): string {
  if (input.output !== undefined) {
    if (input.output.startsWith("/")) return input.output
    return `${input.cwd}/${input.output}`
  }
  return `${input.cwd}/.codex/workflows/${input.workflowName}.ts`
}

function draftScript(input: { readonly workflowName: string; readonly goal: string }): string {
  const escapedName = escapeJsString(input.workflowName)
  const escapedGoal = escapeJsString(input.goal)
  return `export const meta = {
  name: "${escapedName}",
  description: "Generated agent-loops workflow for: ${escapedGoal}",
  phases: [
    { title: "Repository scout", detail: "Gather concrete repository facts, constraints, and consequences before designing work." },
    { title: "Workflow design", detail: "Translate facts into a phase graph with explicit barrier versus pipeline choices." },
    { title: "Execution plan", detail: "Produce exact write scope, verification commands, caps, and halt conditions." },
    { title: "Adversarial review", detail: "Default to fail unless the workflow plan is concrete, bounded, and testable." },
  ],
}

const stringList = { type: "array", items: { type: "string" } }
const factList = {
  type: "array",
  items: {
    type: "object",
    required: ["fact", "consequence", "evidence"],
    properties: { fact: { type: "string" }, consequence: { type: "string" }, evidence: { type: "string" } },
    additionalProperties: false,
  },
}
const phaseList = {
  type: "array",
  items: {
    type: "object",
    required: ["title", "purpose", "dependency", "barrierOrPipeline", "justification"],
    properties: {
      title: { type: "string" },
      purpose: { type: "string" },
      dependency: { type: "string" },
      barrierOrPipeline: { type: "string" },
      justification: { type: "string" },
    },
    additionalProperties: false,
  },
}
const scoutSchema = {
  type: "object",
  required: ["area", "facts", "constraints", "risks"],
  properties: { area: { type: "string" }, facts: factList, constraints: stringList, risks: stringList },
  additionalProperties: false,
}
const designSchema = {
  type: "object",
  required: ["summary", "phaseGraph", "constraints"],
  properties: { summary: { type: "string" }, phaseGraph: phaseList, constraints: stringList },
  additionalProperties: false,
}
const planSchema = {
  type: "object",
  required: ["summary", "writeScope", "files", "steps", "verificationCommands", "caps", "haltConditions"],
  properties: {
    summary: { type: "string" },
    writeScope: stringList,
    files: stringList,
    steps: stringList,
    verificationCommands: stringList,
    caps: stringList,
    haltConditions: stringList,
  },
  additionalProperties: false,
}
const reviewSchema = {
  type: "object",
  required: ["accepted", "summary", "failures", "requiredFixes"],
  properties: { accepted: { type: "boolean" }, summary: { type: "string" }, failures: stringList, requiredFixes: stringList },
  additionalProperties: false,
}

const goal = args.goal || "${escapedGoal}"
const scope = args.scope || "repository"
const paths = args.paths || ["Use rg --files to inventory likely files, then read only focused snippets."]
const constraints = args.constraints || ["Preserve existing public contracts unless the operator explicitly expands scope."]
const verificationCommands = args.verificationCommands || ["Run the narrowest relevant validation first, then the package-level gate."]
const scoutAreas = ["structure and ownership", "existing commands and contracts", "risk and verification"]

phase("Repository scout")
const scouts = await parallel(scoutAreas.map((area) => () =>
  agent("Scout first for concrete repository facts and consequences, not broad opinions." +
    "\\nGoal: " + goal +
    "\\nScope: " + JSON.stringify(scope) +
    "\\nSuggested paths: " + JSON.stringify(paths) +
    "\\nArea: " + area +
    "\\n\\nReturn Facts and Consequences as evidence-backed pairs. Include constraints and risks that should shape the workflow. Do not mutate files.",
    { label: "scout-" + area, schema: scoutSchema, isolation: "read-only" })))

phase("Workflow design")
const design = await agent(
  "Design a workflow phase graph from the scout facts. Justify each phase as a barrier or pipeline choice." +
    "\\nGoal: " + goal +
    "\\nOperator constraints: " + JSON.stringify(constraints) +
    "\\nScout results: " + JSON.stringify(scouts) +
    "\\n\\nFor every phase, explain the dependency, whether it is a barrier or pipeline, and why that shape is required.",
  { label: "workflow-design", schema: designSchema, isolation: "read-only" })
if (!design) return { status: "blocked", reason: "Workflow design agent returned no result." }

phase("Execution plan")
const plan = await agent(
  "Produce an execution plan that another agent can run without guessing. Do not mutate files." +
    "\\nGoal: " + goal +
    "\\nWorkflow design: " + JSON.stringify(design) +
    "\\nVerification commands requested: " + JSON.stringify(verificationCommands) +
    "\\n\\nRequire exact files or paths, write scope, ordered steps, verification commands, caps, and halt conditions.",
  { label: "execution-plan", schema: planSchema, isolation: "read-only" })
if (!plan) return { status: "blocked", reason: "Execution plan agent returned no result." }

phase("Adversarial review")
const review = await agent(
  "Adversarially review the workflow plan. Default to fail unless it is concrete, bounded, and testable." +
    "\\nGoal: " + goal +
    "\\nWorkflow design: " + JSON.stringify(design) +
    "\\nExecution plan: " + JSON.stringify(plan) +
    "\\n\\nReject vague file scope, missing verification, missing halt conditions, or unsupported barrier/pipeline choices.",
  { label: "adversarial-review", schema: reviewSchema, isolation: "read-only" })

return { status: review && review.accepted ? "done" : "incomplete", design, plan, review }
`
}

function slugify(value: string): string {
  const words = value.toLowerCase().match(/[a-z0-9]+/g)
  if (words === null) return "workflow"
  return words.slice(0, 8).join("-")
}

function escapeJsString(value: string): string {
  return value.replace(/\\/g, "\\\\").replace(/"/g, '\\"').replace(/\r?\n/g, "\\n")
}
