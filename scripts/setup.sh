#!/bin/bash
# `make setup`: what a fresh checkout needs before `make dev`. Safe to run again.
set -euo pipefail
cd "$(dirname "$0")/.."

fail() { echo "error: $*" >&2; exit 1; }

[ "$(uname -m)" = arm64 ] || fail "Archidea builds on Apple silicon only (the engine is arm64)"
xcode-select -p >/dev/null 2>&1 || fail "the Command Line Tools are missing: xcode-select --install"
swift_version=$(swift --version 2>&1 | sed -nE 's/.*Swift version ([0-9]+\.[0-9]+).*/\1/p' | head -1)
python3 -c "import sys; sys.exit(0 if tuple(map(int, '${swift_version:-0.0}'.split('.'))) >= (5, 9) else 1)" \
  || fail "Swift 5.9 or later is needed (found ${swift_version:-none}): update the Command Line Tools"
echo "✓ Swift $swift_version"

if command -v brew >/dev/null; then
  brew bundle --file Brewfile
else
  echo "note: no Homebrew; make watch needs watchexec (https://github.com/watchexec/watchexec)" >&2
fi

[ -d "vendor/engine/Chromium Framework.framework" ] || scripts/fetch-engine.sh
scripts/fetch-ublock.sh
scripts/fetch-autoconsent.sh
echo "✓ ready: make dev"
