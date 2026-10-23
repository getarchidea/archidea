#!/bin/bash
# Downloads the prebuilt engine pinned in vendor/engine/ENGINE and checks its SHA-256.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
dir="$here/vendor/engine"
# shellcheck source=/dev/null
source "$dir/ENGINE"
name="Chromium Framework"
file="$FILE"
tmp=$(mktemp -d "$dir/.fetch-XXXXXX")
trap 'rm -rf "$tmp"' EXIT

echo "› downloading $file from $REPO $RELEASE" >&2
if command -v gh >/dev/null; then
  gh release download "$RELEASE" -R "$REPO" -p "$file" -D "$tmp"
else
  curl -fL --retry 3 -o "$tmp/$file" "https://github.com/$REPO/releases/download/$RELEASE/$file"
fi
echo "$SHA256  $tmp/$file" | shasum -a 256 -c - >/dev/null || { echo "error: $file doesn't match its SHA-256" >&2; exit 1; }
tar -xJf "$tmp/$file" -C "$tmp"
[ -f "$tmp/$name.framework/Versions/Current/$name" ] || { echo "error: $file holds no $name.framework" >&2; exit 1; }
rm -rf "$dir/$name.framework"
mv "$tmp/$name.framework" "$dir/"
echo "✓ $dir/$name.framework" >&2
