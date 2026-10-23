#!/usr/bin/env python3
"""Release notes from CHANGELOG.md.

  scripts/changelog.py notes v0.2.0     prints that version's section; fails when there's none
  scripts/changelog.py next minor       prints the next version after the newest released one
"""
import re, sys

text = open("CHANGELOG.md").read()
sections = list(re.finditer(r"^## \[([^\]]+)\][^\n]*\n", text, re.M))


def notes(version):
    for index, match in enumerate(sections):
        if match.group(1) == version:
            end = sections[index + 1].start() if index + 1 < len(sections) else len(text)
            body = re.sub(r"\n\[[^\]]+\]: .*", "", text[match.end():end]).strip()
            if body:
                return body
    sys.exit(f"error: CHANGELOG.md has no notes under ## [{version}]")


if len(sys.argv) == 3 and sys.argv[1] == "notes":
    print(notes(sys.argv[2].removeprefix("v")))
elif len(sys.argv) == 3 and sys.argv[1] == "next":
    released = [m.group(1) for m in sections if m.group(1) != "Unreleased"]
    major, minor, patch = (int(x) for x in (released[0] if released else "0.0.0").split("."))
    print({"major": f"{major + 1}.0.0", "minor": f"{major}.{minor + 1}.0", "patch": f"{major}.{minor}.{patch + 1}"}[sys.argv[2]])
else:
    sys.exit(__doc__)
