# Releasing

Maintainer notes. Contributors don't need any of this to build Archidea.

A release is a `v*` tag. Pushing one runs [`.github/workflows/release.yml`](../.github/workflows/release.yml), which
builds the app on GitHub (Apple silicon; Intel joins once there is an x86_64 engine), packs a disk image and the update
zip, signs the files the in-app updater installs, and publishes the GitHub release with `latest.json` and
`SHA256SUMS.txt`.

## Once: update signing

The updater installs a file only if it matches the SHA-256 in `latest.json` *and* carries a
[minisign](https://jedisct1.github.io/minisign/) signature from the key built into the app, whose trusted comment
names that version and file. Make the key on your own machine, never on CI:

```bash
brew install minisign
minisign -G -W -p update-signing-key.pub -s update-signing-key
```

Then, in the GitHub repository under **Settings → Secrets and variables → Actions**:

| Kind | Name | Value |
| --- | --- | --- |
| Variable | `UPDATE_PUBLIC_KEY` | the second line of `update-signing-key.pub` |
| Secret | `UPDATE_SIGNING_KEY` | the whole of `update-signing-key` |

Keep a copy of the secret key somewhere safe outside the laptop. If it's lost, installed copies can never update
again; if it leaks, make a new pair and ship one release signed with the **old** key that carries the **new**
public key.

Release builds fail without the public key, so no published build ends up unable to update. Local builds have no
key and never update.

## Optional: Developer ID and notarisation

Without these the app is signed ad hoc, and people confirm the first launch in **System Settings › Privacy &
Security**. With them it's signed and notarised, and opens like any App Store-free Mac app:

| Kind | Name | Value |
| --- | --- | --- |
| Secret | `MACOS_CERTIFICATE` | the Developer ID Application certificate exported as .p12, base64 |
| Secret | `MACOS_CERTIFICATE_PASSWORD` | its password |
| Secret | `APPLE_ID`, `APPLE_TEAM_ID`, `APPLE_APP_PASSWORD` | for `notarytool` (an app-specific password) |

## Cutting a release

1. Move the notes under `## [Unreleased]` in [CHANGELOG.md](../CHANGELOG.md) to `## [x.y.z] - YYYY-MM-DD`, leave an
   empty `[Unreleased]` above it, and commit. That section becomes the release notes; the workflow refuses a version
   without one.
2. Run `make release` (next patch), `make release-minor`, `make release-major` or `make release v=x.y.z`. It checks the
   changelog, shows the notes, tags and pushes.
3. Watch the run under **Actions**, then go through the checklist below.

## After the workflow finishes

Automation checks that the build carries the version and the release key, is for the right architecture, has an
intact signature and starts. It can't check the installer on a real Mac or the update from the version people have:

- [ ] The release has `latest.json`, `SHA256SUMS.txt` and a `.minisig` next to the zip and the disk image.
- [ ] The `.dmg` opens to the install window, the app installs and opens, Settings › Advanced shows the new version.
- [ ] **Update path**: a copy of the previous release finds this one, installs it on quit (or from the sidebar's
      Restart button) and comes back on the new version.
