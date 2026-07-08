#!/usr/bin/env bash
set -euo pipefail

spec="${1:-SPEC.md}"

if [[ ! -f "$spec" ]]; then
  echo "spec lint: file not found: $spec" >&2
  exit 2
fi

require() {
  local needle="$1"
  if ! grep -Fq "$needle" "$spec"; then
    echo "spec lint: missing marker: $needle" >&2
    exit 1
  fi
}

forbid() {
  local needle="$1"
  if grep -Fq "$needle" "$spec"; then
    echo "spec lint: stale marker present: $needle" >&2
    exit 1
  fi
}

require "## 10. Dataflow core and proposed extensions"
require "dataflow core implemented; remaining surface proposed/deferred"
require '`SPEC-DATAFLOW-PROPOSAL.md` remains design'
require 'provenance, not the primary spec'
require "**Template layer** (§10.4) | **ADOPT / IMPLEMENTED**"
require '**`let`** (§10.5) | **ADOPT / IMPLEMENTED CORE**'
require "**prompt injection** (§10.6) | **ADOPT / IMPLEMENTED CORE**"
require '**`emit`** (§10.7) | **ADOPT / IMPLEMENTED CORE**'
require '**`gather`** (§10.9) | **DEFER**'
require '**`map`** (§10.9) | **DEFER**'
require '**`reduce`** (§10.10) | **REJECT**'
require '**`select` / `when`** (§10.10) | **REJECT**'
require "Principle 6 → 6′"
require 'presented as **PROPOSED** amendments to the base'
require "draft-improve-report"
require "review-gated-composition"
require 'Interpolated prompt `agent("do #{x}")`'
require "Unbound dataflow assign"
require "Template in a nested position"
require 'It MUST keep `gather` and `map`'
require 'out of the accepted surface until'
require 'those DEFER sections are promoted'

forbid "## 10. Proposed extensions — Tier-1 dataflow (NOT YET IMPLEMENTED)"
forbid "the entire dataflow surface remains unimplemented"
forbid "This section is a design for a *dataflow extension*"

echo "spec lint: ok ($spec)"
