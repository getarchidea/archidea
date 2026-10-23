#!/bin/bash
# Builds build/Archidea.app without Xcode: swiftc + the prebuilt Chromium engine.
#   ./build.sh            debug build
#   ./build.sh release    optimized build
set -euo pipefail
cd "$(dirname "$0")"
root=$PWD
name="Chromium Framework"
engine="$root/vendor/engine/$name.framework"
out="$root/build"
app="$out/Archidea.app"
config=${1:-debug}

[ -d "$engine" ] || "$root/scripts/fetch-engine.sh"

# A stable identity keeps macOS privacy grants (microphone, camera…) across rebuilds; ad hoc signatures
# change with every build, so macOS treats each one as a new app and asks again.
identity=${DRIFT_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/ { print $2; exit }')}
identity=${identity:--}
# Developer ID builds are for notarisation: hardened runtime and a secure timestamp. Chromium's helpers (renderer,
# GPU…) need JIT and unsigned executable memory under it.
runtime=()
case "$identity" in "Developer ID"*) runtime=(--options runtime --timestamp) ;; esac

flags=(-Onone -g -DDEBUG)
[ "$config" = release ] && flags=(-O -wmo)
# Development hooks (scripted walkthroughs and self-checks) live in Sources/Dev, which isn't published.
[ -d Sources/Dev ] && [ "$config" != release ] && flags+=(-DDRIFT_DEV)

mkdir -p "$out" "$app/Contents/MacOS" "$app/Contents/Frameworks" "$app/Contents/Resources"

echo "› compiling ($config)"
sources=()
while IFS= read -r -d '' file; do sources+=("$file"); done < <(find Sources -name '*.swift' -not -path 'Sources/DockTile/*' -print0)
swiftc "${flags[@]}" -swift-version 5 -target arm64-apple-macos14.0 \
  -import-objc-header Sources/Bridging.h -I vendor/engine \
  -F vendor/engine -framework "$name" \
  -Xlinker -rpath -Xlinker @executable_path/../Frameworks -lsqlite3 \
  -o "$app/Contents/MacOS/Archidea" "${sources[@]}"

# The Dock's plug-in that shows the chosen icon while the app isn't running.
plugin="$app/Contents/PlugIns/ArchideaDockTile.docktileplugin"
mkdir -p "$plugin/Contents/MacOS"
cp Resources/DockTile/Info.plist "$plugin/Contents/Info.plist"
swiftc -O -swift-version 5 -target arm64-apple-macos14.0 -parse-as-library -module-name ArchideaDockTile \
  -emit-executable -Xlinker -bundle -o "$plugin/Contents/MacOS/ArchideaDockTile" Sources/DockTile/*.swift

"$root/scripts/check-strings.sh"
"$root/scripts/fetch-ublock.sh"
mkdir -p "$app/Contents/Resources/Extensions"
rsync -a --delete "$root/vendor/ublock/ext/" "$app/Contents/Resources/Extensions/ublock/"
cp Resources/Info.plist "$app/Contents/Info.plist"
# Where updates come from: ARCHIDEA_RELEASES=owner/name, else the GitHub remote of this checkout, if any.
releases=${ARCHIDEA_RELEASES:-$(git -C "$root" config --get remote.origin.url 2>/dev/null | sed -nE 's#.*github\.com[:/]([^/]+/[^/]+)$#\1#p' | sed 's/\.git$//' || true)}
if [ -n "$releases" ]; then /usr/libexec/PlistBuddy -c "Set :ArchideaReleases $releases" "$app/Contents/Info.plist"; fi
for table in Resources/*.lproj; do
  rm -rf "$app/Contents/Resources/$(basename "$table")"
  cp -R "$table" "$app/Contents/Resources/"
done
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$app/Contents/Resources/"
rsync -a --delete Resources/Icons/ "$app/Contents/Resources/Icons/"
# Older builds put a custom icon on the bundle (Icon\r + Finder info), which codesign refuses; clear it.
rm -f "$app/Icon"$'\r'
xattr -d com.apple.FinderInfo "$app" 2>/dev/null || true

# The engine is 300+ MB: clone it (APFS, instant) and re-sign only when it changed.
stamp="$out/.engine-stamp"
want="$(stat -f '%m %z' "$engine/Versions/Current/$name") $identity"
if [ ! -f "$stamp" ] || [ "$(cat "$stamp")" != "$want" ] || [ ! -d "$app/Contents/Frameworks/$name.framework" ]; then
  echo "› embedding the engine"
  rm -rf "$app/Contents/Frameworks/$name.framework"
  cp -cR "$engine" "$app/Contents/Frameworks/"
  fw="$app/Contents/Frameworks/$name.framework"
  fwv=$(cd "$fw/Versions/Current" && pwd -P)
  sign() { codesign --force ${runtime[@]+"${runtime[@]}"} $([ ${#runtime[@]} -eq 0 ] && echo --timestamp=none) --sign "$identity" "$@" >/dev/null 2>&1; }
  for lib in "$fwv"/Libraries/*.dylib; do [ -e "$lib" ] && sign "$lib"; done
  for helper in "$fwv"/Helpers/*.app; do [ -e "$helper" ] && sign --entitlements "$root/Resources/Helper.entitlements" "$helper"; done
  for tool in "$fwv"/Helpers/chrome_crashpad_handler "$fwv"/Helpers/app_mode_loader "$fwv"/Helpers/web_app_shortcut_copier; do
    [ -e "$tool" ] && sign "$tool"
  done
  sign "$fw"
  echo "$want" > "$stamp"
fi

echo "› signing ($identity)"
codesign --force ${runtime[@]+"${runtime[@]}"} $([ ${#runtime[@]} -eq 0 ] && echo --timestamp=none) --sign "$identity" "$plugin" >/dev/null
codesign --force ${runtime[@]+"${runtime[@]}"} $([ ${#runtime[@]} -eq 0 ] && echo --timestamp=none) --sign "$identity" \
  --entitlements Resources/Archidea.entitlements "$app" >/dev/null
echo "✓ $app"
