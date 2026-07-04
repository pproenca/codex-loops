# Codex Loops

Codex Loops is a local, path-first dynamic workflow runner for Codex. It ships a
runtime package, an embedded status UI, and a Codex plugin skill for authoring,
testing, running, and inspecting deterministic workflow scripts.

Install and run the runtime package as `agent-loops`.

## Packages

- `apps/runtime`: npm package `agent-loops`, CLI binary `agent-loops`.
- `apps/status-ui`: npm package `agent-loops-ui`, standalone status UI binary.
- `plugins/codex-loops`: Codex plugin with one `codex-loops` skill.
- `docs`: standalone usage and runtime documentation.

## Install The Codex Plugin

Install from the public Git marketplace:

```sh
codex plugin marketplace add pproenca/codex-loops --ref master
codex plugin add codex-loops@codex-loops
```

Or install from a local clone:

```sh
git clone https://github.com/pproenca/codex-loops.git
cd codex-loops
codex plugin marketplace add .
codex plugin add codex-loops@codex-loops
```

Start a new Codex thread after installing so the `codex-loops` skill is loaded.

## Quick Start

```sh
npx -y agent-loops draft --goal 'Audit auth boundaries' --name auth-audit --json
npx -y agent-loops validate auth-audit --args '{"scope":"auth"}' --json --no-input
npx -y agent-loops test auth-audit --args '{"scope":"auth"}' --provider mock --budget small --json --no-input
npx -y agent-loops workflow auth-audit --args '{"scope":"auth"}' --provider sdk --approved --json --no-input
npx -y agent-loops status --json
```

If installed globally or linked locally, the executable is:

```sh
agent-loops help
```

## Development

```sh
pnpm install
pnpm run check
pnpm run pack:packages
```

Node 24 or newer is required.

## License

MIT. See [LICENSE](LICENSE).
