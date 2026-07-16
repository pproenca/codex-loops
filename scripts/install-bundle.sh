#!/bin/sh
set -eu

source_root=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
version=$(tr -d '[:space:]' < "$source_root/VERSION")
share_root=${CODEX_LOOPS_INSTALL_ROOT:-"$HOME/.local/share/codex-loops"}
bin_root=${CODEX_LOOPS_BIN_ROOT:-"$HOME/.local/bin"}

case "$version" in
  "" | .* | */* | *[!0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz._-]*)
    echo "bundle VERSION is not a safe path component: $version" >&2
    exit 1
    ;;
esac

case "$share_root:$bin_root" in
  /*:/*) ;;
  *)
    echo "Codex Loops install and bin roots must be absolute paths" >&2
    exit 1
    ;;
esac

destination="$share_root/$version"
stage="$share_root/.${version}.$$"
lock="$share_root/.install-lock"
lock_pid_file="$lock/pid"
reclaim_lock="$lock.reclaim"
reclaim_pid_file="$reclaim_lock/pid"
current_link="$share_root/current"
command_link="$bin_root/codex-loops"
next_current="$share_root/.current.$$"
next_command="$bin_root/.codex-loops.$$"
created_destination=0
completed=0
owns_reclaim=0
reclaim_owner=
current_activated=0
command_activated=0
inner_started=0
interrupted=0
old_current=
old_command=

validate_bundle() {
  root=$1
  test -d "$root" &&
    test ! -L "$root" &&
    test -x "$root/bin/codex-loops" &&
    test -x "$root/libexec/scheduler/bin/agent_loops" &&
    test -x "$root/libexec/scheduler/bin/codex-loops-server" &&
    test -f "$root/share/skills/codex-loops/SKILL.md" &&
    test -f "$root/share/codex-loops/THIRD_PARTY_NOTICES.md" &&
    test -f "$root/share/codex-loops/runtime.json"
}

replace_link() {
  case $(uname -s) in
    Linux) mv -fT "$1" "$2" ;;
    *) mv -fh "$1" "$2" ;;
  esac
}

restore_link() {
  path=$1
  target=$2

  if [ -n "$target" ]; then
    temporary="$path.restore.$$"
    rm -f "$temporary"
    ln -s "$target" "$temporary"
    replace_link "$temporary" "$path"
  else
    rm -f "$path"
  fi
}

link_matches() {
  test -L "$1" && test "$(readlink "$1" 2>/dev/null || true)" = "$2"
}

restore_link_if_installed() {
  path=$1
  installed_target=$2
  previous_target=$3

  if link_matches "$path" "$installed_target"; then
    restore_link "$path" "$previous_target"
  else
    echo "preserving a concurrently changed Codex Loops link: $path" >&2
  fi
}

handle_signal() {
  interrupted=1
  exit "$1"
}

cleanup() {
  status=$?
  rm -rf "$stage"
  rm -f "$next_current" "$next_command"

  # Once reconciliation starts, an interrupted inner installer may already have
  # persisted a service definition that references this exact version. Keep the
  # activation and immutable destination so rerunning ./install recovers forward.
  if [ "$completed" != "1" ] && { [ "$inner_started" != "1" ] || [ "$interrupted" != "1" ]; }; then
    if [ "$current_activated" = "1" ] && [ "$command_activated" = "1" ]; then
      if link_matches "$current_link" "$version" &&
        link_matches "$command_link" "$share_root/current/bin/codex-loops"; then
        restore_link "$command_link" "$old_command" || true
        restore_link "$current_link" "$old_current" || true
      else
        echo "preserving concurrently changed Codex Loops activation links" >&2
      fi
    elif [ "$current_activated" = "1" ]; then
      restore_link_if_installed "$current_link" "$version" "$old_current" || true
    fi
  fi

  # Version destinations are immutable and safe to reuse. Never remove one on
  # failure: a partially completed inner reconciliation or a concurrent link may
  # already reference its absolute release path.
  : "$created_destination"

  if [ -f "$lock_pid_file" ] && [ "$(cat "$lock_pid_file" 2>/dev/null || true)" = "$$" ]; then
    rm -f "$lock_pid_file"
    rmdir "$lock" 2>/dev/null || true
  fi

  release_reclaim_lock >/dev/null 2>&1 || true
  exit "$status"
}

release_reclaim_lock() {
  if [ "$owns_reclaim" != "1" ]; then
    return
  fi

  released="$reclaim_lock.release.$$"
  release_attempt=0

  while [ "$release_attempt" -lt 20 ]; do
    release_attempt=$((release_attempt + 1))
    rm -rf "$released"

    if [ -L "$reclaim_lock" ] && [ "$(readlink "$reclaim_lock" 2>/dev/null || true)" = "$reclaim_owner" ] &&
      mv "$reclaim_lock" "$released" 2>/dev/null &&
      [ "$(readlink "$released" 2>/dev/null || true)" = "$reclaim_owner" ]; then
      rm -f "$released"
      rm -rf "$reclaim_owner"
      owns_reclaim=0
      reclaim_owner=
      return
    fi

    if [ -L "$released" ] && [ ! -e "$reclaim_lock" ] && [ ! -L "$reclaim_lock" ]; then
      mv "$released" "$reclaim_lock" 2>/dev/null || true
    fi

    sleep 0.01
  done

  return 1
}

reclaim_owned() {
  test "$owns_reclaim" = "1" && test -L "$reclaim_lock" &&
    test "$(readlink "$reclaim_lock" 2>/dev/null || true)" = "$reclaim_owner"
}

wait_for_reclaim_ownership() {
  ownership_attempt=0

  while [ "$ownership_attempt" -lt 20 ]; do
    if reclaim_owned; then return; fi
    ownership_attempt=$((ownership_attempt + 1))
    sleep 0.01
  done

  echo "another Codex Loops installation changed the reclaim lock during acquisition: $reclaim_lock" >&2
  exit 1
}

acquire_lock() {
  # Every acquisition passes through a short-lived gate. Without this gate, two
  # installers that both observe the same dead PID can successively rename or
  # delete each other's newly acquired main lock.
  acquire_reclaim_lock

  if mkdir "$lock" 2>/dev/null; then
    printf '%s\n' "$$" >"$lock_pid_file"
    release_reclaim_lock
    return
  fi

  holder=$(cat "$lock_pid_file" 2>/dev/null || true)

  if valid_pid "$holder" && kill -0 "$holder" 2>/dev/null; then
    echo "another Codex Loops installation is already in progress (pid $holder): $lock" >&2
    exit 1
  fi

  if [ "$(cat "$lock_pid_file" 2>/dev/null || true)" != "$holder" ]; then
    echo "another Codex Loops installation changed the lock owner: $lock" >&2
    exit 1
  fi

  wait_for_reclaim_ownership
  rm -rf "$lock"

  if ! mkdir "$lock" 2>/dev/null; then
    echo "another Codex Loops installation acquired the lock: $lock" >&2
    exit 1
  fi

  printf '%s\n' "$$" >"$lock_pid_file"
  release_reclaim_lock
}

valid_pid() {
  case "$1" in
    "" | *[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

acquire_reclaim_lock() {
  reclaim_owner="$reclaim_lock.owner.$$.$(date +%s)"
  rm -rf "$reclaim_owner"
  mkdir "$reclaim_owner"
  printf '%s\n' "$$" >"$reclaim_owner/pid"

  if ln -s "$reclaim_owner" "$reclaim_lock" 2>/dev/null; then
    if [ -L "$reclaim_lock" ] && [ "$(readlink "$reclaim_lock" 2>/dev/null || true)" = "$reclaim_owner" ]; then
      owns_reclaim=1
      return
    fi

    rm -f "$reclaim_lock/$(basename -- "$reclaim_owner")" 2>/dev/null || true
  fi

  holder=$(cat "$reclaim_pid_file" 2>/dev/null || true)

  if valid_pid "$holder" && kill -0 "$holder" 2>/dev/null; then
    rm -rf "$reclaim_owner"
    reclaim_owner=
    echo "another Codex Loops installation is acquiring or reclaiming the lock (pid $holder): $reclaim_lock" >&2
    exit 1
  fi

  stale_reclaim="$reclaim_lock.stale.$$"
  rm -rf "$stale_reclaim"
  observed_target=$(readlink "$reclaim_lock" 2>/dev/null || true)
  observed_holder=$holder

  if [ "$(readlink "$reclaim_lock" 2>/dev/null || true)" != "$observed_target" ] ||
    [ "$(cat "$reclaim_pid_file" 2>/dev/null || true)" != "$observed_holder" ]; then
    rm -rf "$reclaim_owner"
    reclaim_owner=
    echo "another Codex Loops installation changed the reclaim lock before recovery: $reclaim_lock" >&2
    exit 1
  fi

  if ! mv "$reclaim_lock" "$stale_reclaim" 2>/dev/null; then
    rm -rf "$reclaim_owner"
    reclaim_owner=
    echo "another Codex Loops installation changed the reclaim lock: $reclaim_lock" >&2
    exit 1
  fi

  moved_target=$(readlink "$stale_reclaim" 2>/dev/null || true)
  moved_holder=$(cat "$stale_reclaim/pid" 2>/dev/null || true)

  if [ "$moved_target" != "$observed_target" ] || [ "$moved_holder" != "$holder" ]; then
    if [ ! -e "$reclaim_lock" ] && [ ! -L "$reclaim_lock" ]; then
      mv "$stale_reclaim" "$reclaim_lock" 2>/dev/null || true
    fi

    rm -rf "$reclaim_owner"
    reclaim_owner=
    echo "another Codex Loops installation changed the reclaim lock owner: $reclaim_lock" >&2
    exit 1
  fi

  if [ -n "$observed_target" ]; then
    case "$observed_target" in
      "$reclaim_lock".owner.*) rm -rf "$observed_target" ;;
    esac
  fi

  rm -rf "$stale_reclaim"

  if ! ln -s "$reclaim_owner" "$reclaim_lock" 2>/dev/null; then
    rm -rf "$reclaim_owner"
    reclaim_owner=
    echo "another Codex Loops installation acquired the reclaim lock: $reclaim_lock" >&2
    exit 1
  fi

  if [ ! -L "$reclaim_lock" ] || [ "$(readlink "$reclaim_lock" 2>/dev/null || true)" != "$reclaim_owner" ]; then
    rm -f "$reclaim_lock/$(basename -- "$reclaim_owner")" 2>/dev/null || true
    rm -rf "$reclaim_owner"
    reclaim_owner=
    echo "another Codex Loops installation changed the reclaim lock after acquisition: $reclaim_lock" >&2
    exit 1
  fi

  owns_reclaim=1
}

for argument do
  case "$argument" in
    --check | --dry-run)
      echo "archive installation is mutating; use codex-loops $argument after installation" >&2
      exit 2
      ;;
  esac
done

validate_bundle "$source_root" || {
  echo "runtime bundle is incomplete: $source_root" >&2
  exit 1
}

mkdir -p "$share_root" "$bin_root"

trap cleanup EXIT
trap 'handle_signal 129' HUP
trap 'handle_signal 130' INT
trap 'handle_signal 143' TERM

acquire_lock

if [ -e "$current_link" ] && [ ! -L "$current_link" ]; then
  echo "refusing to replace a non-symlink runtime activation: $current_link" >&2
  exit 1
fi

if [ -e "$command_link" ] && [ ! -L "$command_link" ]; then
  echo "refusing to replace a non-symlink command: $command_link" >&2
  exit 1
fi

if [ -L "$current_link" ]; then
  old_current=$(readlink "$current_link")

  case "$old_current" in
    "" | */* | .*)
      echo "refusing to replace a runtime activation not owned by Codex Loops: $current_link" >&2
      exit 1
      ;;
  esac

  if ! validate_bundle "$share_root/$old_current"; then
    echo "refusing to replace an invalid active Codex Loops bundle: $share_root/$old_current" >&2
    exit 1
  fi
fi

if [ -L "$command_link" ]; then
  old_command=$(readlink "$command_link")

  if [ "$old_command" != "$share_root/current/bin/codex-loops" ]; then
    echo "refusing to replace a command symlink not owned by Codex Loops: $command_link" >&2
    exit 1
  fi
fi

if [ -e "$destination" ] || [ -L "$destination" ]; then
  if ! validate_bundle "$destination" || ! diff -qr "$source_root" "$destination" >/dev/null; then
    echo "existing immutable bundle is incomplete or differs from the signed source: $destination" >&2
    exit 1
  fi
else
  rm -rf "$stage"
  mkdir -p "$stage"
  cp -R "$source_root/." "$stage/"
  created_destination=1
  mv "$stage" "$destination"
fi

ln -s "$version" "$next_current"
current_activated=1
replace_link "$next_current" "$current_link"

ln -s "$share_root/current/bin/codex-loops" "$next_command"
command_activated=1
replace_link "$next_command" "$command_link"

inner_started=1
"$destination/bin/codex-loops" install "$@"

if ! link_matches "$current_link" "$version" ||
  ! link_matches "$command_link" "$share_root/current/bin/codex-loops" ||
  ! validate_bundle "$destination" ||
  ! diff -qr "$source_root" "$destination" >/dev/null; then
  echo "Codex Loops activation changed during installation; preserving the external links" >&2
  exit 1
fi

completed=1

printf 'Installed Codex Loops %s at %s\n' "$version" "$destination"
printf 'Command: %s\n' "$command_link"
