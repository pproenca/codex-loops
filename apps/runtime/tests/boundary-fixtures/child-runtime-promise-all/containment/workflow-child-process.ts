const WORKFLOW_CHILD_SOURCE = String.raw`
const parallel = (tasks) => Promise.all(tasks.map((task) => task()));
`
