#!/bin/sh
set -eu

destination=${1:?formula destination is required}
version=${2:?package version is required}
artifacts_root=${3:?directory containing all target artifacts is required}

case "$version" in
  "" | .* | */* | *[!0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz._-]*)
    echo "formula version is not a safe release component: $version" >&2
    exit 1
    ;;
esac

if [ ! -d "$artifacts_root" ]; then
  echo "formula artifact directory does not exist: $artifacts_root" >&2
  exit 1
fi

artifacts_root=$(CDPATH='' cd -- "$artifacts_root" && pwd)

archive_hash() {
  target=$1
  archive_name="codex-loops-$version-$target.tar.gz"
  archive="$artifacts_root/$archive_name"
  checksum="$archive.sha256"
  signature="$archive.minisig"

  if [ ! -f "$archive" ] || [ ! -f "$checksum" ] || [ ! -s "$signature" ]; then
    echo "formula requires archive, checksum, and signature for $target" >&2
    exit 1
  fi

  if [ "$(awk 'NF { count += 1 } END { print count + 0 }' "$checksum")" != 1 ]; then
    echo "formula checksum must contain exactly one record: $checksum" >&2
    exit 1
  fi

  hash=$(awk 'NF { print $1 }' "$checksum")
  recorded_name=$(awk 'NF { print $2 }' "$checksum")

  case "$hash" in
    *[!0123456789abcdef]* | "")
      echo "formula checksum is not lowercase SHA-256: $checksum" >&2
      exit 1
      ;;
  esac

  if [ "${#hash}" != 64 ] || [ "$recorded_name" != "$archive_name" ]; then
    echo "formula checksum record does not match $archive_name" >&2
    exit 1
  fi

  actual=$(shasum -a 256 "$archive" | awk '{print $1}')

  if [ "$actual" != "$hash" ]; then
    echo "formula archive does not match its checksum: $archive" >&2
    exit 1
  fi

  printf '%s\n' "$hash"
}

macos_arm_hash=$(archive_hash aarch64-apple-darwin)
macos_intel_hash=$(archive_hash x86_64-apple-darwin)
linux_arm_hash=$(archive_hash aarch64-unknown-linux-gnu)
linux_intel_hash=$(archive_hash x86_64-unknown-linux-gnu)

temporary="$destination.$$"
trap 'rm -f "$temporary"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir -p "$(dirname -- "$destination")"

cat >"$temporary" <<EOF
class CodexLoops < Formula
  desc "Local, path-first workflow scheduler for Codex"
  homepage "https://github.com/pproenca/codex-loops"
  version "${version}"
  license "MIT"

  on_macos do
    on_arm do
      url "https://github.com/pproenca/codex-loops/releases/download/v${version}/codex-loops-${version}-aarch64-apple-darwin.tar.gz"
      sha256 "${macos_arm_hash}"
    end
    on_intel do
      url "https://github.com/pproenca/codex-loops/releases/download/v${version}/codex-loops-${version}-x86_64-apple-darwin.tar.gz"
      sha256 "${macos_intel_hash}"
    end
  end

  on_linux do
    on_arm do
      url "https://github.com/pproenca/codex-loops/releases/download/v${version}/codex-loops-${version}-aarch64-unknown-linux-gnu.tar.gz"
      sha256 "${linux_arm_hash}"
    end
    on_intel do
      url "https://github.com/pproenca/codex-loops/releases/download/v${version}/codex-loops-${version}-x86_64-unknown-linux-gnu.tar.gz"
      sha256 "${linux_intel_hash}"
    end
  end

  def install
    libexec.install Dir["*"]
    bin.install_symlink libexec/"bin/codex-loops"
  end

  def post_install
    system bin/"codex-loops", "install"
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/codex-loops --version")
  end
end
EOF

mv "$temporary" "$destination"
trap - EXIT
