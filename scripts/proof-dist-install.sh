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

home="$tmpdir/home"
HOME="$home" "$stage/install" >/dev/null

version=$(tr -d '[:space:]' < "$repo_root/VERSION")
share_root="$home/.local/share/codex-loops"
stable_command="$home/.local/bin/codex-loops"
test -x "$share_root/$version/bin/codex-loops"
test "$(readlink "$share_root/current")" = "$version"
test "$(readlink "$stable_command")" = "$share_root/current/bin/codex-loops"

codex_stub="$tmpdir/codex"
cat >"$codex_stub" <<'EOF'
#!/bin/sh
case "$*" in
  "--version") echo "codex-cli 9.9.9" ;;
  "mcp list --help") echo "--json" ;;
  "mcp add --help") echo "-- COMMAND" ;;
  "mcp list --json") echo '[]' ;;
  *) exit 9 ;;
esac
EOF
chmod 755 "$codex_stub"
HOME="$home" "$stable_command" install --dry-run --codex "$codex_stub" --json >"$tmpdir/install-plan.json"
runtime_root=$(CDPATH= cd -- "$share_root/$version" && pwd -P)
grep -Fq "\"root\":\"$runtime_root\"" "$tmpdir/install-plan.json" || {
  cat "$tmpdir/install-plan.json" >&2
  exit 1
}
grep -Fq "\"command\":\"$stable_command\"" "$tmpdir/install-plan.json" || {
  cat "$tmpdir/install-plan.json" >&2
  exit 1
}

next_version="${version}-next"
next_stage="$tmpdir/codex-loops-$next_version-test"
cp -R "$stage" "$next_stage"
printf '%s\n' "$next_version" >"$next_stage/VERSION"
mkdir -p "$share_root/$next_version/bin"
cp "$stage/bin/codex-loops" "$share_root/$next_version/bin/codex-loops"
if HOME="$home" "$next_stage/install" >/dev/null 2>&1; then
  echo "installer activated an incomplete existing immutable bundle" >&2
  exit 1
fi
test "$(readlink "$share_root/current")" = "$version"
rm -rf "$share_root/$next_version"
HOME="$home" "$next_stage/install" >/dev/null

test -x "$share_root/$version/bin/codex-loops"
test -x "$share_root/$next_version/bin/codex-loops"
test "$(readlink "$share_root/current")" = "$next_version"

fake_bin="$tmpdir/fake-bin"
failed_dist="$tmpdir/failed-dist"
mkdir -p "$fake_bin"
cat >"$fake_bin/minisign" <<'EOF'
#!/bin/sh
exit 42
EOF
chmod 755 "$fake_bin/minisign"
if PATH="$fake_bin:$PATH" DIST_TARGET=proof MINISIGN_SECRET_KEY="$tmpdir/key" \
  "$repo_root/scripts/package-dist.sh" "$bundle" "$failed_dist" "$version" >/dev/null 2>&1; then
  echo "distribution unexpectedly succeeded with a failing signer" >&2
  exit 1
fi
test ! -e "$failed_dist/codex-loops-$version-proof.tar.gz"
test ! -e "$failed_dist/codex-loops-$version-proof.tar.gz.sha256"
test ! -e "$failed_dist/codex-loops-$version-proof.tar.gz.minisig"

interrupt_bin="$tmpdir/interrupt-bin"
interrupted_dist="$tmpdir/interrupted-dist"
mkdir -p "$interrupt_bin"
cat >"$interrupt_bin/minisign" <<'EOF'
#!/bin/sh
kill -TERM "$PPID"
sleep 1
exit 0
EOF
chmod 755 "$interrupt_bin/minisign"
if PATH="$interrupt_bin:$PATH" DIST_TARGET=proof MINISIGN_SECRET_KEY="$tmpdir/key" \
  "$repo_root/scripts/package-dist.sh" "$bundle" "$interrupted_dist" "$version" >/dev/null 2>&1; then
  echo "distribution unexpectedly survived interrupted signing" >&2
  exit 1
fi
test ! -e "$interrupted_dist/codex-loops-$version-proof.tar.gz"
test ! -e "$interrupted_dist/codex-loops-$version-proof.tar.gz.sha256"
test ! -e "$interrupted_dist/codex-loops-$version-proof.tar.gz.minisig"
test ! -e "$interrupted_dist/.codex-loops-$version-proof.publish-lock"

preserved_dist="$tmpdir/preserved-dist"
preserved_archive="$preserved_dist/codex-loops-$version-proof.tar.gz"
mkdir -p "$preserved_dist"
printf 'existing archive\n' >"$preserved_archive"
printf 'existing checksum\n' >"$preserved_archive.sha256"
printf 'existing signature\n' >"$preserved_archive.minisig"
if PATH="$fake_bin:$PATH" DIST_TARGET=proof MINISIGN_SECRET_KEY="$tmpdir/key" \
  "$repo_root/scripts/package-dist.sh" "$bundle" "$preserved_dist" "$version" >/dev/null 2>&1; then
  echo "distribution unexpectedly replaced immutable artifacts" >&2
  exit 1
fi
test "$(cat "$preserved_archive")" = "existing archive"
test "$(cat "$preserved_archive.sha256")" = "existing checksum"
test "$(cat "$preserved_archive.minisig")" = "existing signature"

partial_dist="$tmpdir/partial-dist"
partial_archive="$partial_dist/codex-loops-$version-proof.tar.gz"
mkdir -p "$partial_dist"
printf 'partial checksum\n' >"$partial_archive.sha256"
printf 'partial signature\n' >"$partial_archive.minisig"
if PATH="$fake_bin:$PATH" DIST_TARGET=proof MINISIGN_SECRET_KEY="$tmpdir/key" \
  "$repo_root/scripts/package-dist.sh" "$bundle" "$partial_dist" "$version" >/dev/null 2>&1; then
  echo "distribution unexpectedly replaced partial immutable artifacts" >&2
  exit 1
fi
test "$(cat "$partial_archive.sha256")" = "partial checksum"
test "$(cat "$partial_archive.minisig")" = "partial signature"

formula="$tmpdir/codex-loops-proof.rb"
"$repo_root/scripts/write-homebrew-formula.sh" "$formula" "$version" proof deadbeef
grep -Fq "codex-loops-$version-proof.tar.gz" "$formula"
grep -Fq 'sha256 "deadbeef"' "$formula"

printf 'Versioned bundle install proof passed\n'
