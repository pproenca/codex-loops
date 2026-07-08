#!/usr/bin/env python3
from pathlib import Path
import sys

if len(sys.argv) != 3:
    raise SystemExit("usage: harden-release.py RELEASE_ROOT RELEASE_NAME")

release_root = Path(sys.argv[1])
release_name = sys.argv[2]
script = release_root / "bin" / release_name
text = script.read_text()
old = '''RELEASE_COOKIE="${RELEASE_COOKIE:-"$(cat "$RELEASE_ROOT/releases/COOKIE")"}"
export RELEASE_COOKIE
'''
new = '''if [ -z "${RELEASE_COOKIE+x}" ]; then
  if [ -f "$RELEASE_ROOT/releases/COOKIE" ]; then
    RELEASE_COOKIE="$(cat "$RELEASE_ROOT/releases/COOKIE")"
  else
    RELEASE_COOKIE="$(dd count=1 bs=16 if=/dev/urandom 2> /dev/null | od -An -tx1 | tr -d ' \n')"
  fi
fi
export RELEASE_COOKIE
'''
text = text.replace(old, new)
text = text.replace('RELEASE_DISTRIBUTION="${RELEASE_DISTRIBUTION:-"sname"}"', 'RELEASE_DISTRIBUTION="${RELEASE_DISTRIBUTION:-"none"}"')
script.write_text(text)
(release_root / "releases" / "COOKIE").unlink(missing_ok=True)
