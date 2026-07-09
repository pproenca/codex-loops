# Codex plugin install and marketplace flow

Date: 2026-07-09

Wayfinder ticket: https://github.com/pproenca/codex-loops/issues/100

Codex source inspected: `/Users/pedroproenca/Documents/Projects/opensource/codex`

## Executive answer

Codex installs plugins through configured marketplaces, not by directly cloning an arbitrary plugin repository at `codex plugin add` time. A marketplace is first added to the user's Codex configuration. A plugin is then selected from one of those marketplace manifests and materialized into a local installed plugin root before Codex loads capabilities.

The install lifecycle is therefore:

1. Add a marketplace source with `codex plugin marketplace add SOURCE`.
2. Codex records the marketplace in `$CODEX_HOME/config.toml`.
3. List/read surfaces discover marketplace manifests from configured roots, optional workspace roots, and curated marketplace roots.
4. `codex plugin add PLUGIN@MARKETPLACE` resolves the marketplace plugin entry.
5. Local plugin sources are read from their existing path; Git and NPM plugin sources are staged first.
6. Codex copies the materialized plugin directory into `$CODEX_HOME/plugins/cache/<marketplace>/<plugin>/<version>`.
7. Codex writes `[plugins."<plugin>@<marketplace>"].enabled = true` in user config.
8. Runtime loading reads `.codex-plugin/plugin.json` or `.claude-plugin/plugin.json` from the installed plugin root, then loads skills, MCP servers, apps, and hooks declared by that manifest.

This means a source-first Codex Loops plugin can rely on Codex to fetch/cache plugin files from a marketplace-declared local, Git, or NPM source. It should not rely on Codex discovering a binary by convention. MCP entrypoints must be declared in plugin metadata and must work from the installed plugin root.

## Marketplace lifecycle

The CLI exposes `plugin add`, `plugin list`, `plugin marketplace`, and `plugin remove`. Plugin add accepts `PLUGIN@MARKETPLACE` or `PLUGIN --marketplace MARKETPLACE`, finds a matching configured marketplace, and calls `PluginsManager::install_plugin`. Source: `codex-rs/cli/src/plugin_cmd.rs:49-65`, `codex-rs/cli/src/plugin_cmd.rs:125-174`.

The marketplace CLI accepts local paths, GitHub shorthand, HTTPS/SSH Git URLs, optional `--ref`, and repeatable `--sparse`. Source: `codex-rs/cli/src/marketplace_cmd.rs:43-78`, `codex-rs/cli/src/marketplace_cmd.rs:145-165`.

Marketplace manifests are looked up under `.agents/plugins/marketplace.json`, `.agents/plugins/api_marketplace.json`, and `.claude-plugin/marketplace.json`. Source: `codex-rs/core-plugins/src/marketplace.rs:20-24`.

Configured marketplaces are stored in `[marketplaces.<name>]` entries with `last_updated`, `last_revision` when known, `source_type`, `source`, optional `ref`, and optional `sparse_paths`. Source: `codex-rs/config/src/marketplace_edit.rs:29-39`, `codex-rs/config/src/marketplace_edit.rs:81-118`.

Local marketplace sources are not copied. Their configured `source` path is used as the marketplace root. Non-local configured marketplaces resolve under `$CODEX_HOME/.tmp/marketplaces/<marketplace>`. Source: `codex-rs/core-plugins/src/installed_marketplaces.rs:12-16`, `codex-rs/core-plugins/src/installed_marketplaces.rs:64-76`.

Git marketplace add clones into a staged directory and moves the result into the marketplace install root. Sparse marketplace add uses `git clone --filter=blob:none --no-checkout`, `git sparse-checkout set`, and `git checkout`. Git is run with `GIT_TERMINAL_PROMPT=0`. Source: `codex-rs/core-plugins/src/marketplace_add/install.rs:7-42`, `codex-rs/core-plugins/src/marketplace_add/install.rs:113-137`.

Marketplace upgrade is Git-oriented. It refreshes configured Git marketplace snapshots; local marketplaces are path references and are not upgraded by Codex. Source: `codex-rs/cli/src/marketplace_cmd.rs:49-52`.

## Plugin sources and cache layout

A marketplace plugin source can be local, Git, or NPM. Git and NPM sources are considered install-materialized sources. Source: `codex-rs/core-plugins/src/marketplace.rs:125-153`.

Marketplace source resolution supports:

- Local paths under the marketplace root, using `.` or normalized `./...`.
- Git URLs, GitHub shorthand, relative Git URLs, file URLs, absolute paths, SSH URLs, and optional subdirectories.
- NPM package names with optional version and registry.

Source: `codex-rs/core-plugins/src/marketplace.rs:592-647`, `codex-rs/core-plugins/src/marketplace.rs:649-748`.

Plugin install materializes the marketplace source, then stores the plugin through `PluginStore`. Source: `codex-rs/core-plugins/src/manager.rs:1421-1469`.

The installed plugin cache root is `$CODEX_HOME/plugins/cache`; plugin data lives under `$CODEX_HOME/plugins/data`. The active plugin root shape is `$CODEX_HOME/plugins/cache/<marketplace>/<plugin>/<version>`, and plugin data is `$CODEX_HOME/plugins/data/<plugin>-<marketplace>`. Source: `codex-rs/core-plugins/src/store.rs:19-21`, `codex-rs/core-plugins/src/store.rs:51-96`.

Version selection comes from the plugin manifest during install, with `local` as the default version. `local` wins over discovered semantic versions when choosing the active root. Source: `codex-rs/core-plugins/src/store.rs:19`, `codex-rs/core-plugins/src/store.rs:98-124`, `codex-rs/core-plugins/src/store.rs:276-284`.

Plugin install validates that the source directory exists, that the manifest name matches the marketplace plugin name, and that the version segment is valid. It then copies the source directory into the cache using a staged/rename flow and removes remote-plugin install metadata. Source: `codex-rs/core-plugins/src/store.rs:287-324`, `codex-rs/core-plugins/src/store.rs:509-600`.

Git plugin sources are cloned into `$CODEX_HOME/plugins/.marketplace-plugin-source-staging`; subdirectory sources use sparse checkout. The selected ref or SHA is checked out when present. Source: `codex-rs/core-plugins/src/loader.rs:1381-1450`, `codex-rs/core-plugins/src/loader.rs:1452-1517`.

NPM plugin sources are materialized by running `npm pack --ignore-scripts` into the same staging area, extracting the package, and validating package metadata. Archive size is capped at 50 MB and extracted size at 250 MB. Source: `codex-rs/core-plugins/src/npm_source.rs:11-14`, `codex-rs/core-plugins/src/npm_source.rs:31-77`, `codex-rs/core-plugins/src/npm_source.rs:79-115`.

## Runtime loading and MCP entrypoints

Codex discovers plugin manifests at `.codex-plugin/plugin.json` first, then `.claude-plugin/plugin.json`. Source: `codex-rs/utils/plugins/src/plugin_namespace.rs:9-18`.

The plugin manifest fields Codex parses are name, version, description, keywords, skills, `mcpServers`, apps, hooks, and interface. There is no install-command or dependency field in the manifest shape inspected for this ticket. Source: `codex-rs/core-plugins/src/manifest.rs:22-45`.

Runtime loading requires an active installed plugin root. If the plugin is not installed, loading reports `plugin is not installed`. Once installed, Codex loads the manifest from the plugin root, then loads skill roots, skills, MCP servers, apps, and hooks. Source: `codex-rs/core-plugins/src/loader.rs:780-846`.

MCP server declarations are loaded either from a manifest object or from MCP config files under the plugin root. Source: `codex-rs/core-plugins/src/loader.rs:1267-1310`.

Plugin MCP config is parsed into ordinary `McpServerConfig` values. For host-owned plugin roots, a relative `cwd` is rewritten relative to the plugin root. Codex normalizes transport spelling and OAuth field names, but command discovery is declarative: the manifest/config tells Codex what to run. Source: `codex-rs/codex-mcp/src/plugin_config.rs:60-69`, `codex-rs/codex-mcp/src/plugin_config.rs:96-154`, `codex-rs/codex-mcp/src/plugin_config.rs:237-285`.

After app-server plugin install, Codex reloads config, signals effective plugin changes, loads MCP servers from the installed path, starts plugin MCP OAuth login flows when needed, and loads plugin app declarations. Source: `codex-rs/app-server/src/request_processors/plugins.rs:1422-1517`.

## App-server protocol surface

The app-server marketplace add request mirrors the CLI shape: `source`, optional `refName`, and optional `sparsePaths`. Source: `codex-rs/app-server-protocol/src/protocol/v2/plugin.rs:66-75`, `codex-rs/app-server/src/request_processors/marketplace_processor.rs:104-128`.

The plugin list request can include working directories. When omitted, only home-scoped marketplaces and the official curated marketplace are considered. Source: `codex-rs/app-server-protocol/src/protocol/v2/plugin.rs:129-137`.

The app-server install request requires exactly one of `marketplacePath` or `remoteMarketplaceName`, plus `pluginName`. Source: `codex-rs/app-server-protocol/src/protocol/v2/plugin.rs:799-805`, `codex-rs/app-server/src/request_processors/plugins.rs:1431-1442`.

The app-server plugin source model exposes local, Git, NPM, and remote catalog sources. For remote catalog entries, download metadata is kept server-side and not exposed through the app-server API. Source: `codex-rs/app-server-protocol/src/protocol/v2/plugin.rs:750-774`.

## Stable enough to depend on

- Codex plugin install is marketplace-first. The durable user operation is "add/list/upgrade/remove marketplaces" plus "add/remove plugins from marketplace entries."
- `.codex-plugin/plugin.json` is the primary plugin manifest path.
- Runtime capabilities are loaded from a local installed plugin root, not from raw marketplace metadata alone.
- `mcpServers` is the right runtime declaration point for Codex Loops' MCP adapter.
- Local, Git, and NPM marketplace plugin sources are first-class concepts in the current marketplace model.
- `npm pack --ignore-scripts` means NPM plugin materialization can fetch a package tarball but should not be treated as a general dependency installation hook.
- Marketplace `--sparse` is supported for Git marketplace sources, and Git plugin source subdirectories are supported for individual plugin entries.

## Risky or implementation-detail assumptions

- The exact cache paths under `$CODEX_HOME/.tmp/marketplaces`, `$CODEX_HOME/plugins/cache`, and `$CODEX_HOME/plugins/.marketplace-plugin-source-staging` are current implementation details even though many tests likely exercise them.
- Relying on install-time execution is unsafe: the inspected manifest shape has no install hook, Git materialization only runs `git`, and NPM materialization uses `npm pack --ignore-scripts`.
- Relying on the marketplace cache as the runtime home is wrong. Codex loads the installed plugin root under the plugin cache.
- Relying on raw remote catalog metadata for runtime files is wrong. For install-materialized sources, listing can show metadata from fallback manifests, but real skills/MCP/apps/hooks require an installed source root.
- Assuming `codex plugin add` can accept a plugin Git repo directly is wrong. Direct Git/local input is accepted by marketplace add, while plugin add selects a plugin from a marketplace.

## Implications for Codex Loops

Cloning the Codex Loops repository with checked-in scheduler/MCP binaries is not required by the Codex plugin install model. Codex can install a plugin from a marketplace-declared Git or NPM source and cache the materialized plugin files locally.

However, Codex does not appear to offer a plugin manifest field that says "run brew install", "run mix release", or "install these system dependencies" during plugin installation. If Codex Loops removes tracked binaries, the replacement must be one of:

- Publish build artifacts outside the source repo and make the plugin package contain only source plus a small launcher that downloads/verifies the right artifact on first run.
- Publish an NPM package whose tarball already contains the needed runtime artifact, knowing Codex will use `npm pack --ignore-scripts`.
- Publish a GitHub release/Homebrew/NPM installer and make the plugin's MCP command fail closed with clear setup guidance when the runtime is missing.
- Propose or implement an upstream Codex plugin dependency/install-hook feature, if later research shows no acceptable source-first package path.

For this ticket, the key decision input is that Codex's current stable integration point is a materialized plugin root plus declarative MCP config. Dependency installation is a separate question and should be resolved by the follow-up dependency ticket before designing the Codex Loops migration.
