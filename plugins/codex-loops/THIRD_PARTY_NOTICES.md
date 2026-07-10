# Third-Party Notices

The source-only plugin launches a Homebrew runtime whose native control plane
includes the following direct MCP dependency:

| Package | Version | License | Source |
| --- | --- | --- | --- |
| `rmcp` | `2.2.0` | `Apache-2.0` | <https://github.com/modelcontextprotocol/rust-sdk> |

The packaged Elixir release contains the workflow scheduler; the `rmcp`-based
Rust binary contains only CLI, MCP transport, HTTP adapter, and local lifecycle
coordination behavior.
