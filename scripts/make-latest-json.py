#!/usr/bin/env python3
"""Writes latest.json — what installed copies read to find a new version — from a release folder.

Each platform entry names the update zip (url, sha256, size, minisign signature) and the installer next to it.
  scripts/make-latest-json.py --release-dir release --tag v0.2.0 --repo getarchidea/archidea --notes-file notes.md
"""
import argparse, datetime, hashlib, json, os, plistlib, sys

parser = argparse.ArgumentParser()
parser.add_argument("--release-dir", required=True)
parser.add_argument("--tag", required=True)
parser.add_argument("--repo", required=True)
parser.add_argument("--notes-file", required=True)
parser.add_argument("--minimum-system", default="14.0")
args = parser.parse_args()

version = args.tag.removeprefix("v")
base = f"https://github.com/{args.repo}/releases/download/{args.tag}"


def entry(name):
    path = os.path.join(args.release_dir, name)
    digest = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            digest.update(chunk)
    signature_path = path + ".minisig"
    if not os.path.exists(signature_path):
        sys.exit(f"error: {name} has no signature")
    return {"url": f"{base}/{name}", "sha256": digest.hexdigest(), "size": os.path.getsize(path),
            "signature": open(signature_path).read()}


platforms = {}
for arch in ("arm64", "amd64"):
    update = f"archidea-darwin-{arch}.app.zip"
    if os.path.exists(os.path.join(args.release_dir, update)):
        platforms[f"darwin-{arch}"] = {**entry(update), "installer": entry(f"archidea-{version}-darwin-{arch}.dmg")}
if not platforms:
    sys.exit("error: no update zips in the release folder")

with open(os.path.join(args.release_dir, "latest.json"), "w") as f:
    json.dump({
        "version": version,
        "notes": open(args.notes_file).read().strip(),
        "pub_date": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "minimumSystemVersion": args.minimum_system,
        "platforms": platforms,
    }, f, indent=2)
print(f"latest.json: {version}, {', '.join(platforms)}")
