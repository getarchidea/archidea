#!/bin/bash
# Packs build/Archidea.app for a release, into build/release:
#   archidea-<version>-darwin-arm64.dmg (+ .minisig)   the installer
#   archidea-darwin-arm64.app.zip (+ .minisig)         what installed copies update from
#   SHA256SUMS.txt, latest.json                         checksums, and the manifest the updater reads
# Signatures use the release key (minisign): MINISIGN_KEY names its file, ~/.config/archidea/minisign.key otherwise.
#   scripts/package.sh <owner/repo> [notes-file]
set -euo pipefail
cd "$(dirname "$0")/.."
repo=${1:?usage: scripts/package.sh <owner/repo> [notes-file]}
notes=${2:-}
key=${MINISIGN_KEY:-$HOME/.config/archidea/minisign.key}
[ -f "$key" ] || { echo "error: no release signing key at $key" >&2; exit 1; }
command -v minisign >/dev/null || { echo "error: minisign isn't installed (brew install minisign)" >&2; exit 1; }

app=build/Archidea.app
out=build/release
plist="$app/Contents/Info.plist"
version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$plist")
minimum=$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" "$plist")
zip="archidea-darwin-arm64.app.zip"
dmg="archidea-$version-darwin-arm64.dmg"
rm -rf "$out"
mkdir -p "$out"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

echo "› app zip"
ditto -c -k --keepParent "$app" "$out/$zip"

echo "› installer background"
cat > "$work/background.swift" <<'SWIFT'
import AppKit
// The installer window, 660 × 420: warm off-white, the name set in New York, a quiet arrow from the app to
// Applications. Drawn at 1x and 2x so it's sharp on Retina screens.
func draw(scale: CGFloat, to path: String) {
    let size = NSSize(width: 660, height: 420)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGradient(colors: [NSColor(srgbRed: 0.985, green: 0.98, blue: 0.97, alpha: 1), NSColor(srgbRed: 0.94, green: 0.935, blue: 0.925, alpha: 1)])!
        .draw(in: NSRect(origin: .zero, size: size), angle: -90)
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.9), NSColor.white.withAlphaComponent(0)])!
        .draw(fromCenter: NSPoint(x: 330, y: 330), radius: 0, toCenter: NSPoint(x: 330, y: 330), radius: 300, options: [])

    let center = NSMutableParagraphStyle()
    center.alignment = .center
    let serif = NSFont.systemFont(ofSize: 30, weight: .semibold).fontDescriptor.withDesign(.serif)
        .flatMap { NSFont(descriptor: $0, size: 30) } ?? NSFont.systemFont(ofSize: 30, weight: .semibold)
    NSAttributedString(string: "Archidea", attributes: [
        .font: serif, .foregroundColor: NSColor(white: 0.08, alpha: 1), .paragraphStyle: center, .kern: -0.3,
    ]).draw(in: NSRect(x: 0, y: 338, width: 660, height: 40))
    NSAttributedString(string: "Drag Archidea into Applications to install it", attributes: [
        .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor(white: 0.45, alpha: 1), .paragraphStyle: center,
    ]).draw(in: NSRect(x: 0, y: 312, width: 660, height: 20))

    // The arrow arcs gently over the gap between the two icons (centred at x 190 and 470, y 185 from the bottom).
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: 268, y: 192))
    arrow.curve(to: NSPoint(x: 390, y: 192), controlPoint1: NSPoint(x: 300, y: 222), controlPoint2: NSPoint(x: 358, y: 222))
    arrow.lineWidth = 2
    arrow.lineCapStyle = .round
    arrow.setLineDash([0.5, 6], count: 2, phase: 0)
    NSColor(white: 0.55, alpha: 1).setStroke()
    arrow.stroke()
    let head = NSBezierPath()
    head.move(to: NSPoint(x: 379, y: 202))
    head.line(to: NSPoint(x: 392, y: 191))
    head.line(to: NSPoint(x: 377, y: 186))
    head.lineWidth = 2
    head.lineCapStyle = .round
    head.lineJoinStyle = .round
    head.stroke()

    NSAttributedString(string: "Requires macOS 14 or later", attributes: [
        .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor(white: 0.6, alpha: 1), .paragraphStyle: center,
    ]).draw(in: NSRect(x: 0, y: 28, width: 660, height: 16))
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}
draw(scale: 1, to: CommandLine.arguments[1])
draw(scale: 2, to: CommandLine.arguments[2])
SWIFT
swift "$work/background.swift" "$work/bg.png" "$work/bg@2x.png"
tiffutil -cathidpicheck "$work/bg.png" "$work/bg@2x.png" -out "$work/background.tiff" >/dev/null

echo "› disk image"
stage="$work/stage"
mkdir -p "$stage/.background"
ditto "$app" "$stage/Archidea.app"
ln -s /Applications "$stage/Applications"
cp "$work/background.tiff" "$stage/.background/background.tiff"
rw="$work/rw.dmg"
hdiutil create -quiet -volname "Archidea" -srcfolder "$stage" -fs APFS -format UDRW -size 600m -ov "$rw"
attached=$(hdiutil attach -readwrite -noverify -noautoopen "$rw")
device=$(echo "$attached" | awk '/\/Volumes\// { print $1; exit }')
volume=$(echo "$attached" | awk -F'\t' '/\/Volumes\// { print $NF; exit }')
disk=$(basename "$volume")
# Finder lays the window out and remembers it in the image's .DS_Store.
osascript - "$disk" <<'OSA' || echo "  (Finder layout skipped)"
on run argv
tell application "Finder"
  tell disk (item 1 of argv)
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 860, 568}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 128
    set text size of opts to 13
    set background picture of opts to file ".background:background.tiff"
    set position of item "Archidea.app" of container window to {190, 235}
    set position of item "Applications" of container window to {470, 235}
    -- With hidden files shown, the image's own files would sit on top of the picture: they go far below it.
    repeat with leftover in {".background", ".fseventsd", ".Trashes", ".VolumeIcon.icns", ".DS_Store"}
      try
        set position of item (leftover as text) of container window to {330, 900}
      end try
    end repeat
    update without registering applications
    delay 2
    close
  end tell
end tell
end run
OSA
# The volume's own icon goes on once Finder is done with the window (it drops the file when it's there earlier),
# and is moved down with the others.
cp Resources/Icons/dark-amethyst.icns "$volume/.VolumeIcon.icns"
SetFile -c icnC "$volume/.VolumeIcon.icns" 2>/dev/null || true
SetFile -a C "$volume" 2>/dev/null || true
osascript - "$disk" <<'OSA' >/dev/null 2>&1 || true
on run argv
tell application "Finder"
  try
    set position of item ".VolumeIcon.icns" of container window of disk (item 1 of argv) to {330, 900}
  end try
end tell
end run
OSA
chflags hidden "$volume/.background" "$volume/.VolumeIcon.icns"
rm -rf "$volume/.Trashes"
sync
hdiutil detach -quiet "$device" || hdiutil detach -quiet -force "$device"
hdiutil convert -quiet "$rw" -format ULFO -o "$out/$dmg"
identity=${DRIFT_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Developer ID Application|Apple Development/ { print $2; exit }')}
[ -n "$identity" ] && codesign --force --sign "$identity" "$out/$dmg" >/dev/null 2>&1 || true

echo "› signatures, checksums, latest.json"
for file in "$zip" "$dmg"; do
  minisign -S -l -s "$key" -m "$out/$file" -t "archidea $version $file" -x "$out/$file.minisig" >/dev/null </dev/null
done
( cd "$out" && shasum -a 256 "$dmg" "$dmg.minisig" "$zip" "$zip.minisig" > SHA256SUMS.txt )
base="https://github.com/$repo/releases/download/v$version"
python3 - "$out" "$version" "$minimum" "$base" "$zip" "$dmg" "$notes" <<'PY'
import json, sys, datetime, hashlib, os
out, version, minimum, base, zip_, dmg, notes = sys.argv[1:]
def sha(name):
    h = hashlib.sha256()
    with open(os.path.join(out, name), "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""): h.update(chunk)
    return h.hexdigest()
def entry(name):
    return {"url": f"{base}/{name}", "sha256": sha(name), "size": os.path.getsize(os.path.join(out, name)),
            "signature": open(os.path.join(out, name + ".minisig")).read()}
json.dump({
    "version": version,
    "notes": open(notes).read().strip() if notes else "",
    "pub_date": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "minimumSystemVersion": minimum,
    "platforms": {"darwin-arm64": {**entry(zip_), "installer": entry(dmg)}},
}, open(os.path.join(out, "latest.json"), "w"), indent=2)
PY
ls -lh "$out"
