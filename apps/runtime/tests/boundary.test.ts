import assert from "node:assert/strict"
import { spawnSync } from "node:child_process"
import { test } from "node:test"

test("boundary harness passes for the scaffold", () => {
  const result = spawnSync(process.execPath, ["scripts/check-boundaries.mjs"], {
    cwd: new URL("..", import.meta.url),
    encoding: "utf8",
  })
  assert.equal(result.status, 0, result.stderr)
  assert.match(result.stdout, /boundary checks passed/)
})

test("boundary harness rejects dynamic import bypasses", () => {
  const result = spawnSync(process.execPath, ["scripts/check-boundaries.mjs", "tests/boundary-fixtures/dynamic-import"], {
    cwd: new URL("..", import.meta.url),
    encoding: "utf8",
  })
  assert.notEqual(result.status, 0)
  assert.match(result.stderr, /dynamic import is only allowed/)
})

test("boundary harness rejects export-from Node bypasses", () => {
  const result = spawnSync(process.execPath, ["scripts/check-boundaries.mjs", "tests/boundary-fixtures/export-node"], {
    cwd: new URL("..", import.meta.url),
    encoding: "utf8",
  })
  assert.notEqual(result.status, 0)
  assert.match(result.stderr, /journal\/file writes must go through consistency/)
})

test("boundary harness rejects Proven minting outside trust", () => {
  const result = spawnSync(process.execPath, ["scripts/check-boundaries.mjs", "tests/boundary-fixtures/proven-mint"], {
    cwd: new URL("..", import.meta.url),
    encoding: "utf8",
  })
  assert.notEqual(result.status, 0)
  assert.match(result.stderr, /Proven minting/)
})

test("boundary harness rejects JournalStore implementations outside consistency", () => {
  const result = spawnSync(process.execPath, ["scripts/check-boundaries.mjs", "tests/boundary-fixtures/journal-store"], {
    cwd: new URL("..", import.meta.url),
    encoding: "utf8",
  })
  assert.notEqual(result.status, 0)
  assert.match(result.stderr, /JournalStore implementations are only allowed/)
})

test("boundary harness rejects aliased JournalStore implementations outside consistency", () => {
  const result = spawnSync(process.execPath, ["scripts/check-boundaries.mjs", "tests/boundary-fixtures/journal-store-alias"], {
    cwd: new URL("..", import.meta.url),
    encoding: "utf8",
  })
  assert.notEqual(result.status, 0)
  assert.match(result.stderr, /JournalStore implementations are only allowed/)
})

test("boundary harness rejects JournalStore-shaped object literals outside consistency", () => {
  const result = spawnSync(process.execPath, ["scripts/check-boundaries.mjs", "tests/boundary-fixtures/journal-store-object"], {
    cwd: new URL("..", import.meta.url),
    encoding: "utf8",
  })
  assert.notEqual(result.status, 0)
  assert.match(result.stderr, /JournalStore-shaped object literals/)
})

test("boundary harness rejects JournalStore-shaped classes outside consistency", () => {
  const result = spawnSync(process.execPath, ["scripts/check-boundaries.mjs", "tests/boundary-fixtures/journal-store-class"], {
    cwd: new URL("..", import.meta.url),
    encoding: "utf8",
  })
  assert.notEqual(result.status, 0)
  assert.match(result.stderr, /JournalStore-shaped classes/)
})

test("boundary harness rejects JournalStore-shaped property classes outside consistency", () => {
  const result = spawnSync(process.execPath, ["scripts/check-boundaries.mjs", "tests/boundary-fixtures/journal-store-property-class"], {
    cwd: new URL("..", import.meta.url),
    encoding: "utf8",
  })
  assert.notEqual(result.status, 0)
  assert.match(result.stderr, /JournalStore-shaped classes/)
})

test("boundary harness rejects read-only journal readers in consistency", () => {
  const result = spawnSync(process.execPath, ["scripts/check-boundaries.mjs", "tests/boundary-fixtures/journal-reader-consistency"], {
    cwd: new URL("..", import.meta.url),
    encoding: "utf8",
  })
  assert.notEqual(result.status, 0)
  assert.match(result.stderr, /JournalReader implementations are only allowed|JournalReader-shaped classes/)
})

test("boundary harness rejects trust parsers inside effects", () => {
  const result = spawnSync(process.execPath, ["scripts/check-boundaries.mjs", "tests/boundary-fixtures/effects-trust"], {
    cwd: new URL("..", import.meta.url),
    encoding: "utf8",
  })
  assert.notEqual(result.status, 0)
  assert.match(result.stderr, /effects may not import trust/)
})

test("boundary harness rejects raw JSON.parse outside trust", () => {
  const result = spawnSync(process.execPath, ["scripts/check-boundaries.mjs", "tests/boundary-fixtures/json-parse"], {
    cwd: new URL("..", import.meta.url),
    encoding: "utf8",
  })
  assert.notEqual(result.status, 0)
  assert.match(result.stderr, /JSON\.parse is only allowed/)
})

test("boundary harness keeps the Acorn parser localized to workflow-script trust", () => {
  const result = spawnSync(process.execPath, ["scripts/check-boundaries.mjs", "tests/boundary-fixtures/acorn-wrong-trust"], {
    cwd: new URL("..", import.meta.url),
    encoding: "utf8",
  })
  assert.notEqual(result.status, 0)
  assert.match(result.stderr, /only trust\/workflow-script\.ts may import acorn/)
})

test("boundary harness rejects in-process VM workflow execution", () => {
  const result = spawnSync(process.execPath, ["scripts/check-boundaries.mjs", "tests/boundary-fixtures/in-process-vm"], {
    cwd: new URL("..", import.meta.url),
    encoding: "utf8",
  })
  assert.notEqual(result.status, 0)
  assert.match(result.stderr, /in-process VM execution is not allowed/)
})

test("boundary harness rejects direct child_process effects", () => {
  const result = spawnSync(process.execPath, ["scripts/check-boundaries.mjs", "tests/boundary-fixtures/direct-child-process"], {
    cwd: new URL("..", import.meta.url),
    encoding: "utf8",
  })
  assert.notEqual(result.status, 0)
  assert.match(result.stderr, /subprocesses must go through containment/)
})

test("boundary harness rejects JSON.parse aliases outside trust", () => {
  const result = spawnSync(process.execPath, ["scripts/check-boundaries.mjs", "tests/boundary-fixtures/json-parse-alias"], {
    cwd: new URL("..", import.meta.url),
    encoding: "utf8",
  })
  assert.notEqual(result.status, 0)
  assert.match(result.stderr, /JSON\.parse aliases are only allowed/)
})

test("boundary harness rejects SDK effects without containment import", () => {
  const result = spawnSync(process.execPath, ["scripts/check-boundaries.mjs", "tests/boundary-fixtures/sdk-without-containment"], {
    cwd: new URL("..", import.meta.url),
    encoding: "utf8",
  })
  assert.notEqual(result.status, 0)
  assert.match(result.stderr, /must import runContainedAgentTurn/)
})

test("boundary harness rejects SDK effects that import but do not call containment", () => {
  const result = spawnSync(process.execPath, ["scripts/check-boundaries.mjs", "tests/boundary-fixtures/sdk-unused-containment"], {
    cwd: new URL("..", import.meta.url),
    encoding: "utf8",
  })
  assert.notEqual(result.status, 0)
  assert.match(result.stderr, /must call runContainedAgentTurn/)
})

test("boundary harness rejects SDK calls outside containment operation", () => {
  const result = spawnSync(process.execPath, ["scripts/check-boundaries.mjs", "tests/boundary-fixtures/sdk-outside-containment"], {
    cwd: new URL("..", import.meta.url),
    encoding: "utf8",
  })
  assert.notEqual(result.status, 0)
  assert.match(result.stderr, /SDK calls must occur inside runContainedAgentTurn operation/)
})

test("boundary harness rejects SDK aliases outside containment", () => {
  const result = spawnSync(process.execPath, ["scripts/check-boundaries.mjs", "tests/boundary-fixtures/sdk-alias"], {
    cwd: new URL("..", import.meta.url),
    encoding: "utf8",
  })
  assert.notEqual(result.status, 0)
  assert.match(result.stderr, /SDK aliases are only allowed|SDK calls must occur/)
})

test("boundary harness rejects shadowed containment helper names", () => {
  const result = spawnSync(process.execPath, ["scripts/check-boundaries.mjs", "tests/boundary-fixtures/sdk-shadow-containment"], {
    cwd: new URL("..", import.meta.url),
    encoding: "utf8",
  })
  assert.notEqual(result.status, 0)
  assert.match(result.stderr, /SDK calls must occur inside runContainedAgentTurn operation|must call runContainedAgentTurn/)
})

test("boundary harness rejects block-scoped containment helper shadowing", () => {
  const result = spawnSync(process.execPath, ["scripts/check-boundaries.mjs", "tests/boundary-fixtures/sdk-block-shadow"], {
    cwd: new URL("..", import.meta.url),
    encoding: "utf8",
  })
  assert.notEqual(result.status, 0)
  assert.match(result.stderr, /shadowing runContainedAgentTurn|SDK calls must occur/)
})

test("boundary harness rejects workflow policy construction in effects", () => {
  const result = spawnSync(process.execPath, ["scripts/check-boundaries.mjs", "tests/boundary-fixtures/effects-policy"], {
    cwd: new URL("..", import.meta.url),
    encoding: "utf8",
  })
  assert.notEqual(result.status, 0)
  assert.match(result.stderr, /workflow policy\/default construction belongs in core/)
})

test("boundary harness inspects embedded workflow child runtime source", () => {
  const result = spawnSync(process.execPath, ["scripts/check-boundaries.mjs", "tests/boundary-fixtures/child-runtime-hidden-require"], {
    cwd: new URL("..", import.meta.url),
    encoding: "utf8",
  })
  assert.notEqual(result.status, 0)
  assert.match(result.stderr, /workflow child runtime may not use require/)
})

test("boundary harness rejects embedded workflow child scheduling policy", () => {
  const result = spawnSync(process.execPath, ["scripts/check-boundaries.mjs", "tests/boundary-fixtures/child-runtime-promise-all"], {
    cwd: new URL("..", import.meta.url),
    encoding: "utf8",
  })
  assert.notEqual(result.status, 0)
  assert.match(result.stderr, /must not schedule with Promise\.all/)
})
