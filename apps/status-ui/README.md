# agent-loops-ui

Standalone/static TanStack status UI package and development server for Codex
Loops workflow runs.

## Usage

Normal Codex Loops operator flows should use the main CLI:

```bash
npx -y agent-loops workflow <script-or-name> \
  --args '<json>' \
  --journal .agent-loops-runs/<name>.jsonl \
  --provider sdk \
  --budget <small|standard|deep> \
  --approved \
  --background \
  --status-server \
  --json \
  --no-input
```

For an existing run, use:

```bash
npx -y agent-loops serve --journal <journal.jsonl> --json
```

Direct `agent-loops-ui` execution remains available for package testing and
standalone use:

```bash
npx agent-loops-ui <journal.jsonl>
```

By default the server binds to `127.0.0.1` on an available port and prints the
local URL.

```bash
npx agent-loops-ui <journal.jsonl> --port 63268
npx agent-loops-ui <journal.jsonl> --json
```

The package includes a CLI server and a browser app. The server reads the
Codex Loops journal, projects it into the status payload, and serves the app
next to these endpoints:

- `/status.json` returns the current workflow status payload.
- `/events` streams status payload updates with server-sent events.
- All other non-asset routes fall back to `index.html` for TanStack Router.

## Build

```bash
pnpm -C apps/status-ui typecheck
pnpm -C apps/status-ui build
```

The publish tarball includes only:

- `dist/`
- `bin/`
- `server/`
- `README.md`
- `LICENSE`
- `package.json`

`prepack` runs `pnpm run build`, so `pnpm -C apps/status-ui pack` verifies
the package contents before publishing.

## License

MIT. See [LICENSE](LICENSE).
