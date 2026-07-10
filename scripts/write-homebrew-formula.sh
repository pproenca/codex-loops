#!/bin/sh
set -eu

destination=${1:?formula destination is required}
version=${2:?package version is required}
target=${3:?distribution target is required}
sha256=${4:?archive sha256 is required}

cat >"$destination" <<EOF
class CodexLoops < Formula
  desc "Local, path-first workflow scheduler for Codex"
  homepage "https://github.com/pproenca/codex-loops"
  url "https://github.com/pproenca/codex-loops/releases/download/v${version}/codex-loops-${version}-${target}.tar.gz"
  version "${version}"
  sha256 "${sha256}"
  license "MIT"

  def install
    libexec.install Dir["*"]
    bin.install_symlink libexec/"bin/codex-loops"
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/codex-loops --version")
  end
end
EOF
