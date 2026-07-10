# Third-Party Notices

The skill-only plugin contains no executable runtime or third-party code. The
separately distributed native control plane includes this direct MCP dependency:

| Package | Version | License | Source |
| --- | --- | --- | --- |
| `rmcp` | `2.2.0` | `Apache-2.0` | <https://github.com/modelcontextprotocol/rust-sdk> |

The packaged Elixir release contains the workflow scheduler; the `rmcp`-based
Rust binary contains only CLI, MCP transport, HTTP adapter, and local lifecycle
coordination behavior.
