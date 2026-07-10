#!/bin/sh
set -eu

bundle=${1:?development bundle is required}
repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

stage="$tmpdir/codex-loops-0.2.7-test"
mkdir -p "$stage"
cp -R "$bundle/." "$stage/"
cp "$repo_root/scripts/install-bundle.sh" "$stage/install"
cp "$repo_root/VERSION" "$stage/VERSION"
chmod 755 "$stage/install"

HOME="$tmpdir/home" \
  CODEX_LOOPS_INSTALL_ROOT="$tmpdir/share/codex-loops" \
  CODEX_LOOPS_BIN_ROOT="$tmpdir/bin" \
  "$stage/install" >/dev/null

version=$(tr -d '[:space:]' < "$repo_root/VERSION")
test -x "$tmpdir/share/codex-loops/$version/bin/codex-loops"
test "$(readlink "$tmpdir/share/codex-loops/current")" = "$version"
test "$(readlink "$tmpdir/bin/codex-loops")" = "$tmpdir/share/codex-loops/current/bin/codex-loops"

next_version="${version}-next"
next_stage="$tmpdir/codex-loops-$next_version-test"
cp -R "$stage" "$next_stage"
printf '%s\n' "$next_version" >"$next_stage/VERSION"
HOME="$tmpdir/home" \
  CODEX_LOOPS_INSTALL_ROOT="$tmpdir/share/codex-loops" \
  CODEX_LOOPS_BIN_ROOT="$tmpdir/bin" \
  "$next_stage/install" >/dev/null

test -x "$tmpdir/share/codex-loops/$version/bin/codex-loops"
test -x "$tmpdir/share/codex-loops/$next_version/bin/codex-loops"
test "$(readlink "$tmpdir/share/codex-loops/current")" = "$next_version"

printf 'Versioned bundle install proof passed\n'
