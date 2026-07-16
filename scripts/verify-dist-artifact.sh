#!/usr/bin/env bash
set -euo pipefail

archive=${1:?archive is required}
checksum=${2:?checksum is required}
signature=${3:?signature is required}
public_key=${4:?minisign public key is required}
target=${5:?distribution target is required}
version=${6:?version is required}

for command in minisign shasum tar jq; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "$command is required to verify a distribution artifact" >&2
    exit 1
  }
done

for component in "$version" "$target"; do
  case "$component" in
    "" | .* | */* | *[!0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz._-]*)
      echo "distribution version and target must be safe path components: $component" >&2
      exit 1
      ;;
  esac
done

name="codex-loops-$version-$target"
expected_archive="$name.tar.gz"

if [[ $(basename -- "$archive") != "$expected_archive" ]]; then
  echo "distribution archive name does not match version and target: $archive" >&2
  exit 1
fi

for file in "$archive" "$checksum" "$signature" "$public_key"; do
  [[ -f $file ]] || {
    echo "distribution verification input does not exist: $file" >&2
    exit 1
  }
done

if [[ $(awk 'NF { count += 1 } END { print count + 0 }' "$checksum") != 1 ]]; then
  echo "distribution checksum must contain exactly one record: $checksum" >&2
  exit 1
fi

recorded_hash=$(awk 'NF { print $1 }' "$checksum")
recorded_name=$(awk 'NF { print $2 }' "$checksum")

if [[ ! $recorded_hash =~ ^[0123456789abcdef]{64}$ || $recorded_name != "$expected_archive" ]]; then
  echo "distribution checksum record does not match $expected_archive" >&2
  exit 1
fi

actual_hash=$(shasum -a 256 "$archive" | awk '{print $1}')

if [[ $actual_hash != "$recorded_hash" ]]; then
  echo "distribution archive does not match its checksum: $archive" >&2
  exit 1
fi

minisign -V -q -p "$public_key" -m "$archive" -x "$signature"

tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/codex-loops-dist-verify.XXXXXX")
trap 'rm -rf "$tmpdir"' EXIT
entries="$tmpdir/entries"
tar -tzf "$archive" >"$entries"

[[ -s $entries ]] || {
  echo "distribution archive is empty: $archive" >&2
  exit 1
}

while IFS= read -r entry; do
  entry=${entry%/}

  case "$entry" in
    "$name" | "$name"/*) ;;
    *)
      echo "distribution archive contains an unexpected root: $entry" >&2
      exit 1
      ;;
  esac

  case "/$entry/" in
    */../* | */./*)
      echo "distribution archive contains an unsafe path: $entry" >&2
      exit 1
      ;;
  esac
done <"$entries"

tar -xzf "$archive" -C "$tmpdir"
root="$tmpdir/$name"

test "$(tr -d '[:space:]' <"$root/VERSION")" = "$version"
test -x "$root/install"
test -x "$root/bin/codex-loops"
test -x "$root/libexec/scheduler/bin/agent_loops"
test -x "$root/libexec/scheduler/bin/codex-loops-server"
test -f "$root/share/skills/codex-loops/SKILL.md"
test -f "$root/share/codex-loops/THIRD_PARTY_NOTICES.md"

jq --exit-status --arg version "$version" --arg target "$target" \
  '.schema == "codex-loops.runtime.v1" and .package_version == $version and .target == $target' \
  "$root/share/codex-loops/runtime.json" >/dev/null

printf 'Verified %s\n' "$archive"
