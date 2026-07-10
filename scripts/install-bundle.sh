#!/bin/sh
set -eu

source_root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
version=$(tr -d '[:space:]' < "$source_root/VERSION")
share_root=${CODEX_LOOPS_INSTALL_ROOT:-"$HOME/.local/share/codex-loops"}
bin_root=${CODEX_LOOPS_BIN_ROOT:-"$HOME/.local/bin"}
destination="$share_root/$version"
stage="$share_root/.${version}.$$"

validate_bundle() {
  root=$1
  test -x "$root/bin/codex-loops" &&
    test -x "$root/libexec/scheduler/bin/agent_loops" &&
    test -f "$root/share/skills/codex-loops/SKILL.md" &&
    test -f "$root/share/codex-loops/runtime.json"
}

validate_bundle "$source_root" || {
  echo "runtime bundle is incomplete: $source_root" >&2
  exit 1
}

mkdir -p "$share_root" "$bin_root"
if [ -e "$destination" ]; then
  validate_bundle "$destination" && diff -qr "$source_root" "$destination" >/dev/null || {
    echo "existing immutable bundle is incomplete or differs from the signed source: $destination" >&2
    exit 1
  }
else
  rm -rf "$stage"
  mkdir -p "$stage"
  cp -R "$source_root/." "$stage/"
  mv "$stage" "$destination"
fi

next_current="$share_root/.current.$$"
ln -s "$version" "$next_current"
mv -fh "$next_current" "$share_root/current"

next_command="$bin_root/.codex-loops.$$"
ln -s "$share_root/current/bin/codex-loops" "$next_command"
mv -fh "$next_command" "$bin_root/codex-loops"

printf 'Installed Codex Loops %s at %s\n' "$version" "$destination"
printf 'Next: %s install --codex /absolute/path/to/codex\n' "$bin_root/codex-loops"
