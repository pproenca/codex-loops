const WORKFLOW_CHILD_SOURCE = String.raw`
const fs = require("node:fs");
const message = JSON.parse("{}");
process.stdout.write(String(message));
`
