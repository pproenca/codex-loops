#!/usr/bin/env bash
set -euo pipefail

source_root=${1:?source bundle is required}
dist_root=${2:?distribution directory is required}
version=${3:?version is required}
target=${DIST_TARGET:-$(rustc -vV | sed -n 's/^host: //p')}
name="codex-loops-${version}-${target}"
stage="$dist_root/$name"
archive="$dist_root/$name.tar.gz"
checksum="$archive.sha256"
signature="$archive.minisig"
pending_archive="$dist_root/.${name}.$$.tar.gz"
pending_checksum="$pending_archive.sha256"
pending_signature="$pending_archive.minisig"
lock="$dist_root/.${name}.publish-lock"
owns_publication=0

mkdir -p "$dist_root"
if ! mkdir "$lock" 2>/dev/null; then
  echo "another distribution publication is active for $name" >&2
  exit 1
fi

cleanup() {
  rm -f "$pending_archive" "$pending_checksum" "$pending_signature"
  if [ "$owns_publication" = "1" ] && [ ! -e "$archive" ]; then
    rm -f "$checksum" "$signature"
  fi
  rmdir "$lock" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 1' INT TERM

: "${MINISIGN_SECRET_KEY:?MINISIGN_SECRET_KEY is required for canonical distribution artifacts}"
command -v minisign >/dev/null 2>&1 || {
  echo "minisign is required for canonical distribution artifacts" >&2
  exit 1
}

if [ -e "$archive" ] || [ -e "$checksum" ] || [ -e "$signature" ]; then
  echo "refusing to replace immutable distribution artifacts for $name" >&2
  exit 1
fi
owns_publication=1
rm -rf "$stage"
mkdir -p "$stage"
cp -R "$source_root/." "$stage/"
cp "$(dirname -- "$0")/install-bundle.sh" "$stage/install"
cp "$(dirname -- "$0")/../VERSION" "$stage/VERSION"
chmod 755 "$stage/install"
tar -C "$dist_root" -czf "$pending_archive" "$name"
minisign -S -s "$MINISIGN_SECRET_KEY" -m "$pending_archive"
hash=$(shasum -a 256 "$pending_archive" | awk '{print $1}')
printf '%s  %s\n' "$hash" "$(basename -- "$archive")" >"$pending_checksum"

mv "$pending_signature" "$signature"
mv "$pending_checksum" "$checksum"
mv "$pending_archive" "$archive"
trap - EXIT INT TERM
rmdir "$lock"
"$(dirname -- "$0")/write-homebrew-formula.sh" \
  "$dist_root/codex-loops-$target.rb" "$version" "$target" "$hash"

printf 'Created %s\n' "$archive"
