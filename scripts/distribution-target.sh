#!/bin/sh
set -eu

system=$(uname -s)
machine=$(uname -m)

case "$system:$machine" in
  Darwin:arm64 | Darwin:aarch64)
    printf '%s\n' aarch64-apple-darwin
    ;;
  Darwin:x86_64 | Darwin:amd64)
    printf '%s\n' x86_64-apple-darwin
    ;;
  Linux:aarch64 | Linux:arm64)
    printf '%s\n' aarch64-unknown-linux-gnu
    ;;
  Linux:x86_64 | Linux:amd64)
    printf '%s\n' x86_64-unknown-linux-gnu
    ;;
  *)
    printf 'unsupported distribution target: %s %s\n' "$system" "$machine" >&2
    exit 1
    ;;
esac
