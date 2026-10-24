# Contributing to Archidea

Thanks for helping. Bug reports, ideas and code are all welcome.

## Reporting a bug

Open an [issue](https://github.com/getarchidea/archidea/issues/new/choose) with:

- what you did, what you expected and what happened;
- your macOS version and the Archidea version (Settings › Advanced);
- a screenshot or a screen recording if it's visual.

For focus, click or window problems, a trace helps a lot. Turn it on, reproduce the problem, then attach the log:

```bash
defaults write app.archidea.browser DriftTrace -bool YES
```

The log is written to `~/Library/Application Support/Archidea/trace.log`. Turn it off again with
`defaults delete app.archidea.browser DriftTrace`.

Security issues go to [SECURITY.md](SECURITY.md), not to public issues.

## Building

You need macOS 14 or later on Apple silicon and the Xcode Command Line Tools (`xcode-select --install`, Swift 5.9 or
later). Xcode itself isn't needed: Archidea is a Swift package, and any editor with sourcekit-lsp (Zed's and VS
Code's Swift extensions) reads `Package.swift` for completion and navigation.

```bash
git clone https://github.com/getarchidea/archidea.git
cd archidea
make setup     # checks the toolchain, fetches the engine and the bundled extensions, installs watchexec (Brewfile)
make dev       # builds and runs Archidea in the terminal with a profile of its own; ⌃C quits
```

`make` lists every command. The ones you'll use most:

| Command | What it does |
|---|---|
| `make dev` | Debug build, run in the terminal with the trace on and a separate profile (`build/dev-data`) |
| `make watch` | `make dev` that rebuilds and restarts on every save in `Sources` or `Resources` |
| `make run` | Debug build, opened like any app, with your own profile |
| `make test` | Unit tests (`swift test`) |
| `make lint` / `make format` | swift-format, configured in `.swift-format` |
| `make release-build` | Optimised build |
| `make package` | Disk image and update zip, as a release has them |

`swift build` compiles incrementally, so a change to one file rebuilds in seconds; `scripts/bundle.sh` then packs
the binary into `build/Archidea.app` with the engine, translations and icons (SwiftPM compiles, but it makes no
app bundles). There is no hot reload of running code: a native app around Chromium can't swap code in place
reliably, so `make watch` restarts instead, and the separate profile brings back the same tabs.

The first build downloads the prebuilt Chromium engine (about 95 MB) pinned in `vendor/engine/ENGINE` and checks
its SHA-256, and fetches uBlock Origin for the built-in blocker and DuckDuckGo's autoconsent for cookie banners. If you have an Apple Development or Developer ID
certificate, the build signs with it so macOS remembers camera and microphone permissions between builds;
otherwise it signs ad hoc. `DRIFT_SIGN_IDENTITY` picks a certificate explicitly.

To try a build with a profile of your choice, give it a data folder: `make dev DATA=/tmp/archidea-test`.

## How it's put together

Archidea is Swift and AppKit around a Chromium engine framework that exposes an Objective-C API
(`vendor/engine/ArdiaCore.h`). Chromium owns the process; the app starts once the engine is up.

| Folder | What lives there |
|---|---|
| `Sources/ArchideaCore` | Spaces, tabs, folders and settings, the import merge, address parsing, update checks: Foundation only |
| `Sources/Archidea/App` | Startup, menus, the app icon, updates |
| `Sources/Archidea/Storage` | Saving the sidebar and its icons |
| `Sources/Archidea/Browser` | Live tabs, the ad blocker, password managers, history for suggestions |
| `Sources/Archidea/UI` | The window, sidebar, command bar, settings, site prompts, welcome window |
| `Sources/Archidea/Engine` | Engine startup and calls into Chromium's services |
| `Sources/Archidea/Import` | Reading other browsers' data and bringing it in |
| `Sources/ArchideaDockTile` | The Dock's plug-in that shows the chosen icon while the app isn't running |
| `Tests` | Unit tests for `ArchideaCore` |
| `Resources` | Info.plist, translations, icons |
| `vendor/engine` | The engine's pin, its Objective-C header and the module map that makes it `import ArdiaCore` |

**Translations** live in `Resources/<language>.lproj/Localizable.strings`. Every key used in the code must exist in
every language; the build fails otherwise and lists the missing keys. Keys built at run time are listed in
`Resources/dynamic-keys.txt`.

## Sending a change

1. Fork, branch from `main`, keep the change focused.
2. Match the surrounding code: comments explain *why*, names say *what*.
3. Make sure `make build` and `make test` pass and try the change in the running app.
4. Open a pull request describing what changed and how you checked it. Screenshots for anything visual.

By contributing you agree that your work is released under the project's [license](LICENSE) (GPL-3.0).

## Code of conduct

Be kind and assume good intent. See [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).
