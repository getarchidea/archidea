#!/bin/bash
# Fails when a key used as L("…") in Sources is missing from any Resources/*.lproj/Localizable.strings,
# and checks that every table parses.
set -euo pipefail
cd "$(dirname "$0")/.."
keys=$( (grep -rhoE 'L\("[a-zA-Z0-9_.]+"' Sources --include='*.swift' | sed -E 's/L\("(.*)"/\1/'; grep -v '^#' Resources/dynamic-keys.txt) | sort -u)
status=0
for table in Resources/*.lproj/Localizable.strings; do
  plutil -lint -s "$table" || { echo "error: $table doesn't parse" >&2; status=1; continue; }
  defined=$(plutil -convert json -o - "$table" | python3 -c 'import json,sys; print("\n".join(sorted(json.load(sys.stdin))))')
  missing=$(comm -23 <(echo "$keys") <(echo "$defined"))
  if [ -n "$missing" ]; then
    echo "error: $(dirname "$table" | xargs basename) lacks:" >&2
    echo "$missing" | sed 's/^/  /' >&2
    status=1
  fi
done
exit $status
