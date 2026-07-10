#!/usr/bin/env bash
set -euo pipefail

source_root=${1:?source bundle is required}
dist_root=${2:?distribution directory is required}
version=${3:?version is required}
target=${DIST_TARGET:-$(rustc -vV | sed -n 's/^host: //p')}
name="codex-loops-${version}-${target}"
stage="$dist_root/$name"
archive="$dist_root/$name.tar.gz"

: "${MINISIGN_SECRET_KEY:?MINISIGN_SECRET_KEY is required for canonical distribution artifacts}"
command -v minisign >/dev/null 2>&1 || {
  echo "minisign is required for canonical distribution artifacts" >&2
  exit 1
}

rm -rf "$stage" "$archive" "$archive.sha256" "$archive.minisig"
mkdir -p "$stage"
cp -R "$source_root/." "$stage/"
cp "$(dirname -- "$0")/install-bundle.sh" "$stage/install"
cp "$(dirname -- "$0")/../VERSION" "$stage/VERSION"
chmod 755 "$stage/install"
tar -C "$dist_root" -czf "$archive" "$name"
shasum -a 256 "$archive" > "$archive.sha256"

minisign -S -s "$MINISIGN_SECRET_KEY" -m "$archive"

printf 'Created %s\n' "$archive"
