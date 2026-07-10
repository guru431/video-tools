#!/bin/bash
# Bootstrap local protection for this PUBLIC repo after a fresh clone:
#   1) activate the pre-commit secret guard (core.hooksPath)
#   2) seed the local .sanitize-patterns denylist from the tracked example
# Safe to re-run (idempotent). Windows: use bootstrap-public-repo.cmd.
set -eu
cd "$(dirname "$0")/.."

echo "==> git config core.hooksPath .githooks"
git config core.hooksPath .githooks

if [ ! -f .sanitize-patterns ]; then
  echo "==> creating .sanitize-patterns from .sanitize-patterns.example"
  echo "    Edit it and add your REAL private values (file is gitignored)."
  cp .sanitize-patterns.example .sanitize-patterns
else
  echo "==> .sanitize-patterns already present"
fi

echo "==> done. Commits now run through .githooks/pre-commit."
echo "    Optional history scan (if installed): gitleaks detect --source ."
