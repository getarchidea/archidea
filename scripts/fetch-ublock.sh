#!/bin/bash
# Fetches uBlock Origin for the optional built-in ad blocker: a pinned release, checksum
# and key. The key gives it the fixed ID the engine restricts (no scripts on the Web Store or chrome:// pages).
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
dir="$root/vendor/ublock"
VERSION="1.75.0"
SHA256="393cf95709d1074d4022970e9014e434395c53a822387f1e25f43be97cf4b582"
KEY="MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAv1MPdIgJjIsN4Y0N/20GDNPfN4J//aknk5dsH8Y1LBxSnz3Jp/BT187Gub5cv6lee5CUVDmVBa3Yiqow8GMna5KwX+ZP+yc1pt/ewzyNxm2BzoQPgWz+1DgZaahz56/szi1EEtWVYxd3wNxFN4wPDqwV6aqlnV4R3RnxlF1ocw1kDgJ+8BxR1EY+MB+H8bymdef+xB3TNifBZIVmZt81cC3UMOG6KWRTU1wtIXsW+ZqSv5zaeFHLkjG4MPB7EfcMGrvO80ElJBZZLdrTmYOL4uUPsz2Wy6GiPWzpDmzzI9RfsZm11sLiJo63blcPF0Cz3sM0wQfxJPPcQuqkZDReswIDAQAB"
[ -f "$dir/.version" ] && [ "$(cat "$dir/.version")" = "$VERSION" ] && exit 0
mkdir -p "$dir"
zip="$dir/uBlock0_$VERSION.chromium.zip"
if [ ! -f "$zip" ]; then
  echo "› downloading uBlock Origin $VERSION" >&2
  if command -v gh >/dev/null; then
    gh release download "$VERSION" -R gorhill/uBlock -p "uBlock0_$VERSION.chromium.zip" -D "$dir" --clobber
  else
    curl -fL --retry 3 -o "$zip" "https://github.com/gorhill/uBlock/releases/download/$VERSION/uBlock0_$VERSION.chromium.zip"
  fi
fi
echo "$SHA256  $zip" | shasum -a 256 -c - >/dev/null || { echo "error: uBlock zip doesn't match its SHA-256" >&2; exit 1; }
rm -rf "$dir/unzip" "$dir/ext"
unzip -q "$zip" -d "$dir/unzip"
mv "$dir/unzip/uBlock0.chromium" "$dir/ext"
rm -rf "$dir/unzip"
python3 -I - "$dir/ext/manifest.json" "$KEY" <<'PY'
import json, sys
path, key = sys.argv[1], sys.argv[2]
manifest = json.load(open(path))
manifest["key"] = key
manifest["incognito"] = "spanning"
web = ["http://*/*", "https://*/*", "ws://*/*", "wss://*/*"]
manifest["permissions"] = [p for p in manifest["permissions"] if p != "<all_urls>"] + web
json.dump(manifest, open(path, "w"), indent=2)
PY
echo "$VERSION" > "$dir/.version"
echo "✓ $dir/ext" >&2
