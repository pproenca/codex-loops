#!/usr/bin/env bash
set -euo pipefail

source_root=${1:?source bundle is required}
dist_root=${2:?distribution directory is required}
version=${3:?version is required}
script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
target=${DIST_TARGET:-$("$script_dir/distribution-target.sh")}

for component in "$version" "$target"; do
  case "$component" in
    "" | .* | */* | *[!0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz._-]*)
      echo "distribution version and target must be safe path components: $component" >&2
      exit 1
      ;;
  esac
done

mkdir -p "$dist_root"
dist_root=$(CDPATH='' cd -- "$dist_root" && pwd -P)
name="codex-loops-${version}-${target}"
stage="$dist_root/$name"
archive="$dist_root/$name.tar.gz"
checksum="$archive.sha256"
signature="$archive.minisig"
transaction="$dist_root/.${name}.publication"
transaction_archive="$transaction/archive.tar.gz"
transaction_checksum="$transaction/archive.tar.gz.sha256"
transaction_signature="$transaction/archive.tar.gz.minisig"
transaction_ready="$transaction/ready"
lock="$dist_root/.${name}.publish-lock"
lock_owner=
owns_lock=0

valid_pid() {
  [[ $1 =~ ^[0-9]+$ ]]
}

release_lock() {
  if [[ $owns_lock != 1 ]]; then
    return
  fi

  local released="$lock.release.$$"
  rm -rf "$released"

  if [[ -L $lock ]] && [[ $(readlink "$lock" 2>/dev/null || true) == "$lock_owner" ]] &&
    mv "$lock" "$released" 2>/dev/null &&
    [[ $(readlink "$released" 2>/dev/null || true) == "$lock_owner" ]]; then
    rm -f "$released"
    rm -rf "$lock_owner"
    owns_lock=0
    lock_owner=
    return
  fi

  if [[ -L $released ]] && [[ ! -e $lock && ! -L $lock ]]; then
    mv "$released" "$lock" 2>/dev/null || true
  fi

  return 1
}

acquire_lock() {
  lock_owner="$lock.owner.$$.$(date +%s)"
  rm -rf "$lock_owner"
  mkdir "$lock_owner"
  printf '%s\n' "$$" >"$lock_owner/pid"

  if ln -s "$lock_owner" "$lock" 2>/dev/null; then
    if [[ -L $lock && $(readlink "$lock" 2>/dev/null || true) == "$lock_owner" ]]; then
      owns_lock=1
      return
    fi

    rm -f "$lock/$(basename -- "$lock_owner")" 2>/dev/null || true
  fi

  local holder observed_target stale moved_target moved_holder
  holder=$(cat "$lock/pid" 2>/dev/null || true)

  if valid_pid "$holder" && kill -0 "$holder" 2>/dev/null; then
    rm -rf "$lock_owner"
    lock_owner=
    echo "another distribution publication is active for $name (pid $holder)" >&2
    exit 1
  fi

  observed_target=$(readlink "$lock" 2>/dev/null || true)
  stale="$lock.stale.$$"
  rm -rf "$stale"

  if ! mv "$lock" "$stale" 2>/dev/null; then
    rm -rf "$lock_owner"
    lock_owner=
    echo "another distribution publication changed the lock for $name" >&2
    exit 1
  fi

  moved_target=$(readlink "$stale" 2>/dev/null || true)
  moved_holder=$(cat "$stale/pid" 2>/dev/null || true)

  if [[ $moved_target != "$observed_target" || $moved_holder != "$holder" ]]; then
    if [[ ! -e $lock && ! -L $lock ]]; then
      mv "$stale" "$lock" 2>/dev/null || true
    fi

    rm -rf "$lock_owner"
    lock_owner=
    echo "another distribution publication changed the lock owner for $name" >&2
    exit 1
  fi

  if [[ -n $observed_target && $observed_target == "$lock".owner.* ]]; then
    rm -rf "$observed_target"
  fi

  rm -rf "$stale"

  if ! ln -s "$lock_owner" "$lock" 2>/dev/null; then
    rm -rf "$lock_owner"
    lock_owner=
    echo "another distribution publication acquired the lock for $name" >&2
    exit 1
  fi

  if [[ ! -L $lock || $(readlink "$lock" 2>/dev/null || true) != "$lock_owner" ]]; then
    rm -f "$lock/$(basename -- "$lock_owner")" 2>/dev/null || true
    rm -rf "$lock_owner"
    lock_owner=
    echo "another distribution publication changed the lock after acquisition for $name" >&2
    exit 1
  fi

  owns_lock=1
}

assert_lock() {
  [[ $owns_lock == 1 && -L $lock && $(readlink "$lock" 2>/dev/null || true) == "$lock_owner" ]]
}

cleanup() {
  if [[ ! -L $transaction && -d $transaction && ! -f $transaction_ready ]]; then
    rm -rf "$transaction"
  fi

  release_lock >/dev/null 2>&1 || true
}

valid_transaction() {
  local hash expected
  [[ -f $transaction_ready && -f $transaction_archive && -s $transaction_signature && -f $transaction_checksum ]] || return 1
  hash=$(shasum -a 256 "$transaction_archive" | awk '{print $1}')
  expected="$hash  $(basename -- "$archive")"
  [[ $(cat "$transaction_checksum") == "$expected" ]]
}

publish_file() {
  local source=$1 destination=$2 temporary="$2.pending.$$"

  assert_lock || {
    echo "distribution publication lock changed for $name" >&2
    return 1
  }

  if [[ -e $destination ]]; then
    cmp -s "$source" "$destination" || {
      echo "refusing to replace immutable distribution artifact: $destination" >&2
      return 1
    }
    return
  fi

  rm -f "$temporary"
  cp "$source" "$temporary"
  mv "$temporary" "$destination"
}

resume_publication() {
  valid_transaction || {
    echo "incomplete distribution publication transaction for $name" >&2
    return 1
  }

  publish_file "$transaction_signature" "$signature"
  publish_file "$transaction_checksum" "$checksum"
  publish_file "$transaction_archive" "$archive"
  rm -rf "$transaction"
}

acquire_lock
trap cleanup EXIT
trap 'exit 1' INT TERM

if [[ -L $transaction ]]; then
  echo "refusing a symlink distribution publication transaction: $transaction" >&2
  exit 1
fi

: "${MINISIGN_SECRET_KEY:?MINISIGN_SECRET_KEY is required for canonical distribution artifacts}"
command -v minisign >/dev/null 2>&1 || {
  echo "minisign is required for canonical distribution artifacts" >&2
  exit 1
}

if [[ -f $transaction_ready ]]; then
  resume_publication
else
  rm -rf "$transaction"

  if [[ -e $archive || -e $checksum || -e $signature ]]; then
    echo "refusing to replace immutable distribution artifacts for $name" >&2
    exit 1
  fi

  assert_lock || {
    echo "distribution publication lock changed for $name" >&2
    exit 1
  }

  rm -rf "$stage"
  mkdir -p "$stage" "$transaction"
  cp -R "$source_root/." "$stage/"
  cp "$script_dir/install-bundle.sh" "$stage/install"
  cp "$script_dir/../VERSION" "$stage/VERSION"
  chmod 755 "$stage/install"
  tar -C "$dist_root" -czf "$transaction_archive" "$name"
  minisign -S -s "$MINISIGN_SECRET_KEY" -m "$transaction_archive"
  hash=$(shasum -a 256 "$transaction_archive" | awk '{print $1}')
  printf '%s  %s\n' "$hash" "$(basename -- "$archive")" >"$transaction_checksum"
  : >"$transaction_ready"
  resume_publication
fi

trap - EXIT INT TERM
release_lock

printf 'Created %s\n' "$archive"
