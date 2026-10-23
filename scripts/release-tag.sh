#!/bin/bash
# Checks CHANGELOG.md has notes for <version>, shows them, then tags v<version> and pushes the tag.
set -euo pipefail
cd "$(dirname "$0")/.."
version=${1:?usage: scripts/release-tag.sh <version>}
[ -z "$(git status --porcelain)" ] || { echo "error: commit your changes first" >&2; exit 1; }
notes=$(python3 scripts/changelog.py notes "$version")
echo "Archidea $version"
echo
echo "$notes"
echo
read -r -p "Tag v$version and push? [y/N] " answer
[ "$answer" = y ] || exit 1
git tag -a "v$version" -m "Archidea $version"
git push origin main "v$version"
echo "→ https://github.com/$(git config --get remote.origin.url | sed -E 's#.*github\.com[:/]##; s#\.git$##')/actions"
