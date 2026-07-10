#!/usr/bin/env bash
# lint.sh — checks Rust code for production discipline violations
# Usage: bash lint.sh <file.rs>
set -euo pipefail

FILE="${1:?Usage: lint.sh <file.rs>}"
ERRORS=0

# Find where test module starts (to exclude test code from prod checks)
TEST_LINE=$(grep -n '#\[cfg(test)\]' "$FILE" 2>/dev/null | head -1 | cut -d: -f1 || true)
if [ -z "$TEST_LINE" ]; then
  TEST_LINE=$(wc -l < "$FILE")
fi

# 1. unwrap() in production code
UNWRAPS=$(head -n "$TEST_LINE" "$FILE" | grep -n '\.unwrap()' | grep -v '// lint:allow' || true)
if [ -n "$UNWRAPS" ]; then
  echo "ERROR: unwrap() in production code:"
  echo "$UNWRAPS"
  ERRORS=$((ERRORS + 1))
fi

# 2. HashMap where BTreeMap might be appropriate (in struct definitions)
HASHMAPS=$(head -n "$TEST_LINE" "$FILE" | grep -n 'HashMap' | grep -v 'use ' | grep -v '//' || true)
if [ -n "$HASHMAPS" ]; then
  echo "WARNING: HashMap found — consider BTreeMap for deterministic output:"
  echo "$HASHMAPS"
fi

# 3. Wildcard match arms _ => (excluding slice/tuple/char patterns)
WILDCARDS=$(head -n "$TEST_LINE" "$FILE" | grep -n '_ =>' | grep -v '// lint:allow' || true)
if [ -n "$WILDCARDS" ]; then
  echo "ERROR: Wildcard match arm _ => found — use an exhaustive match or add lint:allow with a reason:"
  echo "$WILDCARDS"
  ERRORS=$((ERRORS + 1))
fi

# 4. bool parameters in public function signatures
BOOL_PARAMS=$(head -n "$TEST_LINE" "$FILE" | grep -n 'pub.*fn.*\bbool\b' | grep -v 'Result<bool' | grep -v -- '-> bool' || true)
if [ -n "$BOOL_PARAMS" ]; then
  echo "ERROR: bool parameter in public function — use a named enum:"
  echo "$BOOL_PARAMS"
  ERRORS=$((ERRORS + 1))
fi

# 5. Tuple return types in public functions
TUPLE_RETURNS=$(head -n "$TEST_LINE" "$FILE" | grep -En 'pub.*fn.*->.*\([^)]*,' | grep -v -e 'impl ' || true)
if [ -n "$TUPLE_RETURNS" ]; then
  echo "ERROR: Tuple return type — use a named struct:"
  echo "$TUPLE_RETURNS"
  ERRORS=$((ERRORS + 1))
fi

# 6. Missing Display impl for public enums
PUB_ENUMS=$(head -n "$TEST_LINE" "$FILE" | grep -c 'pub enum' || true)
DISPLAY_IMPLS=$(grep -c 'impl.*Display\|#\[derive.*Display' "$FILE" || true)
if [ "$PUB_ENUMS" -gt "$DISPLAY_IMPLS" ] 2>/dev/null; then
  echo "INFO: $PUB_ENUMS public enum(s) but only $DISPLAY_IMPLS Display impl(s)"
fi

# 7. Raw external failures must be translated at the operation that produced
# them. Propagating an already typed domain result is allowed because its
# variant retains that operation context.
BARE_Q=$(head -n "$TEST_LINE" "$FILE" \
  | grep -n '?\s*;' \
  | grep -E 'fs::|env::|serde_json::|\.open\(|\.output\(|\.spawn\(|\.wait\(' \
  | grep -v '\.map_err\|\.context\|\.with_context\|// lint:allow' || true)
if [ -n "$BARE_Q" ]; then
  echo "ERROR: Bare ? without .context():"
  echo "$BARE_Q"
  ERRORS=$((ERRORS + 1))
fi

# Summary
if [ "$ERRORS" -gt 0 ]; then
  echo ""
  echo "FAILED: $ERRORS error(s) found"
  exit 1
else
  echo ""
  echo "PASSED (check warnings above)"
  exit 0
fi
