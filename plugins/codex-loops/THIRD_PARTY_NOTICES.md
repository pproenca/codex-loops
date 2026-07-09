# Third-Party Notices

The source-only plugin launches a Homebrew runtime that includes compiled code
from the following direct MCP dependency:

| Package | Version | License | Source |
| --- | --- | --- | --- |
| `anubis_mcp` | `1.6.2` | `LGPL-3.0` | <https://github.com/zoedsoupe/anubis-mcp> |

The Anubis LGPL-3.0 distribution gate is accepted for the current local plugin
and Homebrew-oriented package model. If that model changes or cannot carry the
required notices/source location, replace the MCP layer with the `hermes_mcp`
fallback recorded in `docs/adr/0001-mcp-and-cli-packaging-libraries.md`.
