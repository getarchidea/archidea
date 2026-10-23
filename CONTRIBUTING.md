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

You need macOS 14 or later on Apple silicon, the Xcode Command Line Tools (`xcode-select --install`) and the
GitHub CLI (`gh`) or `curl`. Xcode itself isn't required.

```bash
git clone https://github.com/getarchidea/archidea.git
cd archidea
./build.sh            # debug build → build/Archidea.app
./build.sh release    # optimised build
open build/Archidea.app
```

The first build downloads the prebuilt Chromium engine (about 95 MB) pinned in `vendor/engine/ENGINE` and checks
its SHA-256, and fetches uBlock Origin for the built-in blocker. If you have an Apple Development or Developer ID
certificate, `build.sh` signs with it so macOS remembers camera and microphone permissions between builds;
otherwise it signs ad hoc. `DRIFT_SIGN_IDENTITY` picks a certificate explicitly.

To try a build without touching your own profile, give it a separate data folder:

```bash
DRIFT_DATA_DIR=/tmp/archidea-test build/Archidea.app/Contents/MacOS/Archidea
```

## How it's put together

Archidea is Swift and AppKit around a Chromium engine framework that exposes an Objective-C API
(`vendor/engine/ArdiaCore.h`). Chromium owns the process; the app starts once the engine is up.

| Folder | What lives there |
|---|---|
| `Sources/App` | Startup, menus, translations, the app icon, updates |
| `Sources/Model` | Spaces, tabs, folders and settings, saved as JSON |
| `Sources/Browser` | Live tabs, the ad blocker, password managers, history for suggestions |
| `Sources/UI` | The window, sidebar, command bar, settings, site prompts, welcome window |
| `Sources/Engine` | Engine startup and calls into Chromium's services |
| `Sources/Import` | Reading other browsers' data and bringing it in |
| `Resources` | Info.plist, translations, icons |

**Translations** live in `Resources/<language>.lproj/Localizable.strings`. Every key used in the code must exist in
every language; the build fails otherwise and lists the missing keys. Keys built at run time are listed in
`Resources/dynamic-keys.txt`.

## Sending a change

1. Fork, branch from `main`, keep the change focused.
2. Match the surrounding code: comments explain *why*, names say *what*.
3. Make sure `./build.sh` passes and try the change in the running app.
4. Open a pull request describing what changed and how you checked it. Screenshots for anything visual.

By contributing you agree that your work is released under the project's [license](LICENSE) (GPL-3.0).

## Code of conduct

Be kind and assume good intent. See [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).
