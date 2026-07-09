# Codex plugin dependency and install-command support

Date: 2026-07-09

Wayfinder ticket: https://github.com/pproenca/codex-loops/issues/101

Codex source inspected: `/Users/pedroproenca/Documents/Projects/opensource/codex`

## Executive answer

Codex does not currently provide a plugin-owned or CLI-owned install hook for arbitrary dependency commands such as `brew install`, `npm install`, `mix release`, downloading a runtime artifact, or building after clone.

What Codex does provide today:

- Plugin manifests can declare runtime capability paths: skills, `mcpServers`, apps, hooks, and interface metadata.
- Plugin MCP config can declare a runtime MCP server as stdio command config or streamable HTTP URL.
- Skill metadata can declare tool dependencies in `agents/openai.yaml`.
- A stable, default-on `skill_mcp_dependency_install` feature can prompt for and persist missing MCP server configs for explicitly mentioned skills.
- The model can suggest that the user install a known plugin/connector through `request_plugin_install`.

Those mechanisms are not general package/dependency installation. For Codex Loops, a source-first plugin can declaratively point Codex at the MCP adapter it should run, but it cannot ask Codex's plugin installer to install Elixir, run `mix release`, fetch a GitHub release, or call Homebrew. Adding a true postinstall/build/dependency resolver would require an upstream Codex schema and install-pipeline change.

## Plugin manifest support

`.codex-plugin/plugin.json` is parsed into `RawPluginManifest` with these top-level fields: `name`, `version`, `description`, `keywords`, `skills`, `mcpServers`, `apps`, `hooks`, and `interface`. There is no `dependencies`, `install`, `postinstall`, `setup`, `scripts`, or build-command field in the runtime parser. Source: `codex-rs/core-plugins/src/manifest.rs:22-45`.

The parser deserializes that raw manifest and maps only those fields into `PluginManifest` paths/interface data. Source: `codex-rs/core-plugins/src/manifest.rs:155-180`, `codex-rs/core-plugins/src/manifest.rs:255-267`.

The sample plugin JSON spec in the bundled plugin creator likewise documents top-level fields for metadata and capabilities only: `skills`, `hooks`, `mcpServers`, `apps`, and interface fields. It does not document package-manager dependencies or install scripts. Source: `codex-rs/skills/src/assets/samples/plugin-creator/references/plugin-json-spec.md:51-68`, `codex-rs/skills/src/assets/samples/plugin-creator/references/plugin-json-spec.md:114-119`.

`mcpServers` can be a path or inline object. It is a runtime MCP declaration, not an install hook. Source: `codex-rs/core-plugins/src/manifest.rs:303-329`.

## Plugin materialization still avoids install scripts

Marketplace plugin install materializes the source and copies it into the plugin cache. It does not run a plugin-provided build or setup command. Source: `codex-rs/core-plugins/src/manager.rs:1421-1469`, `codex-rs/core-plugins/src/store.rs:287-324`.

Git plugin sources are cloned and optionally sparse-checked out, then used as the materialized source. Source: `codex-rs/core-plugins/src/loader.rs:1381-1450`, `codex-rs/core-plugins/src/loader.rs:1452-1517`.

NPM plugin sources run `npm pack --ignore-scripts`, extract the package, and validate package metadata. This explicitly avoids NPM lifecycle scripts, so NPM is a package transport here, not a postinstall execution path. Source: `codex-rs/core-plugins/src/npm_source.rs:31-77`, `codex-rs/core-plugins/src/npm_source.rs:79-115`.

## MCP runtime config

Plugin MCP declarations are parsed into normal `McpServerConfig` values. For host-owned plugins, relative `cwd` values are rewritten under the plugin root. Source: `codex-rs/codex-mcp/src/plugin_config.rs:96-154`, `codex-rs/codex-mcp/src/plugin_config.rs:237-285`.

`McpServerConfig` represents runtime server configuration: transport, auth, environment id, enabled/required flags, timeouts, tool approval, allow/deny lists, OAuth settings, and per-tool policy. Source: `codex-rs/config/src/mcp_types.rs:156-223`.

The two runtime transports are stdio and streamable HTTP. Stdio config names a `command`, optional args/env/env_vars/cwd; streamable HTTP names a URL and optional bearer/header settings. Source: `codex-rs/config/src/mcp_types.rs:435-463`.

This means Codex Loops can declare "run this MCP server command from this plugin root" if the command exists. It cannot declare "install the command first" through MCP config.

## Skill dependency metadata

Skill metadata is separate from plugin manifest metadata. The loader reads optional `agents/openai.yaml` next to a skill and accepts `interface`, `dependencies`, and `policy`. Missing or invalid skill metadata fails open and does not block loading `SKILL.md`. Source: `codex-rs/core-skills/src/loader.rs:64-72`, `codex-rs/core-skills/src/loader.rs:838-907`.

The internal model stores `SkillDependencies { tools: Vec<SkillToolDependency> }`; each tool dependency has `type`, `value`, optional `description`, optional `transport`, optional `command`, and optional `url`. Source: `codex-rs/core-skills/src/model.rs:70-83`.

The loader preserves dependency metadata from `agents/openai.yaml`, including non-MCP dependency types such as `cli` in tests. Source: `codex-rs/core-skills/src/loader_tests.rs:427-511`.

However, the documented `agents/openai.yaml` field guide says `dependencies.tools[].type` supports only `mcp` for now. Source: `codex-rs/skills/src/assets/samples/skill-creator/references/openai_yaml.md:16-23`, `codex-rs/skills/src/assets/samples/skill-creator/references/openai_yaml.md:42-46`.

The app-server protocol surfaces this metadata in skill list/read responses, but it is still skill metadata: `SkillMetadata.dependencies` contains `SkillDependencies.tools`. Source: `codex-rs/app-server-protocol/src/protocol/v2/plugin.rs:413-428`, `codex-rs/app-server-protocol/src/protocol/v2/plugin.rs:452-475`, `codex-rs/app-server/src/request_processors/catalog_processor.rs:18-61`.

## Skill MCP dependency auto-install

There is a stable, default-on feature named `skill_mcp_dependency_install`. Source: `codex-rs/features/src/lib.rs:209-210`, `codex-rs/features/src/lib.rs:1195-1200`.

During a turn, Codex collects explicitly mentioned skills and calls `maybe_prompt_and_install_mcp_dependencies` before injecting skill prompts. Source: `codex-rs/core/src/session/turn.rs:579-599`.

That path is intentionally narrow:

- It runs only for first-party originators.
- It requires the `SkillMcpDependencyInstall` feature.
- It considers only mentioned skills.
- It collects only dependencies whose `type` is `mcp`.
- It supports `streamable_http` dependencies with `url` and `stdio` dependencies with `command`.

Source: `codex-rs/core/src/mcp_skill_dependencies.rs:34-79`, `codex-rs/core/src/mcp_skill_dependencies.rs:324-341`, `codex-rs/core/src/mcp_skill_dependencies.rs:411-466`.

When the dependency is missing, Codex may ask the user whether to install MCP servers. If the user accepts, Codex writes MCP server config into global config, performs OAuth login when applicable, refreshes MCP servers, and records which dependency prompts were already shown during the session. Source: `codex-rs/core/src/mcp_skill_dependencies.rs:81-204`, `codex-rs/core/src/mcp_skill_dependencies.rs:206-280`.

The installed MCP config for skill dependencies is minimal. Streamable HTTP dependencies become a URL-based MCP server. Stdio dependencies become an MCP server with only `command` populated and empty args/env/cwd. Source: `codex-rs/core/src/mcp_skill_dependencies.rs:343-409`.

So the word "install" in this feature means "persist and enable an MCP server config." It does not install a binary, a Homebrew package, an NPM dependency graph, an Elixir runtime, or a plugin build output.

## Plugin/connector install suggestions

Codex also has tool discovery surfaces for plugins/connectors that are available but not installed. The model can use `request_plugin_install` to suggest installation of a known discoverable plugin or connector. Source: `codex-rs/tools/src/tool_discovery.rs:5-10`, `codex-rs/core/src/context/recommended_plugins_instructions.rs:1-5`.

The request shape is a user-facing elicitation with metadata such as tool type, install action, tool id/name, optional install URL, optional remote plugin id, and app connector ids. Source: `codex-rs/tools/src/request_plugin_install.rs:15-67`, `codex-rs/tools/src/request_plugin_install.rs:89-113`.

The handler verifies that the suggestion matches known discoverable tools, sends an elicitation through the Apps MCP server, and then verifies whether the plugin/connector became available. Source: `codex-rs/core/src/tools/handlers/request_plugin_install.rs:90-145`, `codex-rs/core/src/tools/handlers/request_plugin_install.rs:213-280`, `codex-rs/core/src/tools/handlers/request_plugin_install.rs:349-409`.

This is not dependency installation either. It is a consent/handoff surface for installing known plugins/connectors.

## Hooks are not postinstall hooks

Plugin manifests can declare runtime hooks. Codex loads them from manifest paths, inline manifest entries, or the default `hooks/hooks.json` file under the installed plugin root. Source: `codex-rs/core-plugins/src/loader.rs:1058-1115`.

The hook event enum includes runtime/session events: pre/post tool use, permission request, pre/post compact, session start, user prompt submit, subagent start/stop, and stop. There is no install, setup, postinstall, or build event. Source: `codex-rs/protocol/src/protocol.rs:1473-1486`.

## Managed install code is Codex-owned, not plugin-owned

The `app-server-daemon` managed install code belongs to Codex's own remote app-server lifecycle. Its README says bootstrap requires the standalone managed Codex install, records daemon settings, starts app-server, and can launch an updater loop that runs `install.sh` for Codex itself. Source: `codex-rs/app-server-daemon/README.md:34-56`.

The managed install helper resolves and invokes `$CODEX_HOME/packages/standalone/current/codex`; it is not a generic plugin package installer. Source: `codex-rs/app-server-daemon/src/managed_install.rs:19-25`, `codex-rs/app-server-daemon/src/managed_install.rs:37-64`.

## Implications for Codex Loops

Codex Loops cannot express its runtime/build dependencies declaratively today except as MCP runtime config and, at the skill level, optional MCP server dependencies. It cannot tell Codex:

- install Homebrew packages,
- run `npm install`,
- run `mix deps.get` or `mix release`,
- download and verify a GitHub release artifact,
- build the plugin after clone,
- run package-manager lifecycle scripts during NPM plugin materialization.

Codex can ask the user to approve installing missing MCP server configs for mentioned skills, and it can ask the user to approve installing a known plugin/connector through `request_plugin_install`. Neither path solves "install Codex Loops runtime artifacts" unless the artifact is already reachable through a declared MCP command or HTTP MCP endpoint.

Therefore, moving Codex Loops out of checked-in binaries should not depend on an existing Codex postinstall mechanism. Viable packaging paths are still external to this ticket: prebuilt artifacts in the plugin package, first-run launcher/bootstrap outside Codex's install lifecycle, Homebrew/NPM/GitHub-release distribution with fail-closed setup guidance, or an upstream Codex feature for plugin install hooks/dependency declarations.

An upstream postinstall/build hook would need at least:

- a plugin manifest schema addition,
- marketplace/plugin install protocol and app-server UI changes,
- an installer execution policy with explicit user approval and fail-closed behavior,
- sandbox/network policy integration,
- audit/logging and tests around command execution,
- a decision about whether NPM materialization should continue using `--ignore-scripts`.
