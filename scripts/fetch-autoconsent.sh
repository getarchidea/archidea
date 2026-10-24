#!/bin/bash
# Fetches DuckDuckGo's autoconsent for hiding cookie banners: a pinned npm release, its checksum, and the key that
# gives it a fixed ID. It answers consent pop-ups the way the person would ("reject all"), and hides the ones it can't.
# The package ships a Chromium (MV3) extension; this keeps what runs (background, content script, rules) and leaves
# out its developer pop-up and DevTools page.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
dir="$root/vendor/autoconsent"
VERSION="16.61.0"
SHA256="f9115f8d899b59c5d74f8b56efa6422859f15e23bf7041a1025e051c5a95d826"
# Its ID: iiefeinnpgnnjpnjpdaaeaefcpnbedal (Sources/Archidea/Browser/BundledExtensions.swift).
KEY="MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAoPVfElAImnFroG2e/PAC4UIBqmnTKNmjRchHlUGRwYqr0vlVfPqoSYQ1N0YGH4ju/2UTQyKQdc4CBfS/8izeV5naEwSS4LeGd7LeGsgo8ZfswcgF4bU7Itgw5d/TaeX5bAq9oB1guIXrjxGuurCckPqcdRFqjWfZxfGKQMQg2wLLYziRC9oAnLFAZIY7IeZ2mkNbrIblYNssTvWNVpYGRAwuC5Kjr06UjWuguMSlmM0F/BOROyIBKsoYaX7K46j5s2DjG2WvuhUw94I2T2v+pdRxH11ULI2aOmJ94EDzG5vGZQsKVm7ERyFO7ceHnk6mgffvTMWDsBCXVW7oRtx8wwIDAQAB"
[ -f "$dir/.version" ] && [ "$(cat "$dir/.version")" = "$VERSION" ] && exit 0
mkdir -p "$dir"
tarball="$dir/autoconsent-$VERSION.tgz"
if [ ! -f "$tarball" ]; then
  echo "› downloading autoconsent $VERSION" >&2
  curl -fL --retry 3 -o "$tarball" "https://registry.npmjs.org/@duckduckgo/autoconsent/-/autoconsent-$VERSION.tgz"
fi
echo "$SHA256  $tarball" | shasum -a 256 -c - >/dev/null || { echo "error: the autoconsent package doesn't match its SHA-256" >&2; exit 1; }
rm -rf "$dir/unpack" "$dir/ext"
mkdir -p "$dir/unpack"
tar -xzf "$tarball" -C "$dir/unpack"
mv "$dir/unpack/package/dist/addon-mv3" "$dir/ext"
cp "$dir/unpack/package/LICENSE" "$dir/ext/LICENSE"
rm -rf "$dir/unpack" "$dir/ext/devtools" "$dir/ext/popup.html" "$dir/ext/popup.bundle.js"
python3 -I - "$dir/ext/manifest.json" "$KEY" <<'PY'
import json, sys
path, key = sys.argv[1], sys.argv[2]
manifest = json.load(open(path))
manifest["name"] = "Cookie banners"
manifest["key"] = key
manifest["incognito"] = "spanning"
manifest.pop("devtools_page", None)
# The background sets the action's title and icon; the action stays, without the developer pop-up.
manifest.setdefault("action", {}).pop("default_popup", None)
manifest.setdefault("action", {}).pop("browser_style", None)
# Nothing in it reads or clears cookies or browsing data.
manifest["permissions"] = [p for p in manifest["permissions"] if p not in ("cookies", "browsingData")]
json.dump(manifest, open(path, "w"), indent=2)
PY
echo "$VERSION" > "$dir/.version"
echo "✓ $dir/ext" >&2
