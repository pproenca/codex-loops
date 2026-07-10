#!/bin/sh
set -eu

source_root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
version=$(tr -d '[:space:]' < "$source_root/VERSION")
share_root=${CODEX_LOOPS_INSTALL_ROOT:-"$HOME/.local/share/codex-loops"}
bin_root=${CODEX_LOOPS_BIN_ROOT:-"$HOME/.local/bin"}
destination="$share_root/$version"
stage="$share_root/.${version}.$$"

test -x "$source_root/bin/codex-loops"
test -x "$source_root/libexec/scheduler/bin/agent_loops"
test -f "$source_root/share/skills/codex-loops/SKILL.md"

mkdir -p "$share_root" "$bin_root"
if [ -e "$destination" ]; then
  test -x "$destination/bin/codex-loops" || {
    echo "existing immutable bundle is incomplete: $destination" >&2
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
