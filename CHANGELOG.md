# Changelog

What changes in each Archidea release. The section for a version becomes its release notes and what the app shows
under *What's new*.

## [Unreleased]

- When an update check fails, Archidea says what happened in plain words (no connection to GitHub, a bad answer,
  an update that didn't verify) instead of the system's raw error.

## [0.1.4] - 2026-10-24

- **Mini window**: a link from another app (a chat, a mail) opens in a small window of its own instead of piling
  up in your sidebar. *Open in Archidea* moves the page into the browser window as it is — scroll position,
  sign-in and all; closing the window lets it go. Settings › General › Links from other apps switches back to
  opening them as tabs.

- Any tab can be renamed (double-click it, or Rename in its menu), and the name stays when the page changes its
  title; “Use the Page’s Title” takes it back.

- Site and app cards in the page's corner move aside when the hidden sidebar slides out, instead of ending up
  underneath it.

## [0.1.3] - 2026-10-24

- **Downloads**: a button at the bottom of the sidebar fills as files come in; its list shows progress and time
  left, pauses, resumes, cancels, opens files, shows them in Finder and lets you drag them out. ⇧⌘J opens it too.
  A link that only downloads a file no longer leaves an empty tab behind.
- New app icons, with a fine grain and soft inner depth, in all ten colours.
- Imported tabs, bookmarks and history bring their site icons along (from Chrome, Arc, Dia, Edge, Brave, Firefox…),
  so they show before you open them again; address suggestions from history carry site icons too.
- Links from other apps (a sign-in link from a desktop app, a link in Mail) open in Archidea again, also when the link
  is what launches it; before, Archidea only came forward.
- A site asking to open another app does it on a card with the app's icon — Cancel, Always or Open — instead of
  the engine's dialog.
- The Dock icon's menu opens a new tab, a private window, or any of your spaces.
- The new-tab bar casts a proper shadow and dims the page behind it; the sidebar stays clickable while it's open.
- Right after an import, the address bar suggests from the imported history straight away.
- Declining the Keychain prompt during import no longer stops the import: everything else comes over, and the
  summary says passwords stayed behind. Other import errors show their actual message.
- If the saved sidebar ever can't be read back, Archidea keeps the damaged file and restores the copy from the
  previous launch instead of starting empty.
- An import can no longer hang on a write the engine never answers, or start twice from onboarding.
- Closing a private window no longer leaves its event handlers and timers running.
- Closing a pinned tab with no open Today tabs moves to another open pin.

## [0.1.2] - 2026-10-24

- Clicks in the sidebar no longer go dead after switching apps: a click into Archidea while macOS still treats it
  as in the background now brings it forward properly.
- Swipe left or right with two fingers on the sidebar to move between spaces; the list follows your fingers.
- The import summary in onboarding shows what came over — tabs, bookmarks, history, passwords — and keeps its
  button clear of the text.

## [0.1.1] - 2026-10-23

- **Help › Save Diagnostic Log** writes what Archidea did lately to a file you can attach to an issue — no
  restart or settings needed, so a problem can be captured while it's happening.
- **Help › Report an Issue** opens the issue tracker.

## [0.1.0] - 2026-10-23

The first release of Archidea — a calm, native Mac browser built around the sidebar.

- Spaces with their own colour, icon and light or dark look; pinned tabs, folders and Today tabs that tidy
  themselves.
- Drag tabs and groups anywhere — into folders, out of them, between spaces.
- Import from Arc (spaces and pins included), Dia, Chrome, Safari, Firefox, Edge, Brave and more.
- Private windows (⇧⌘N), built-in ad and tracker blocking, Chrome Web Store extensions.
- Site requests and password prompts as quiet cards next to the page.
- Updates install themselves from GitHub releases, signed with Archidea's release key.

Requires macOS 14 or later on Apple silicon. This build isn't notarised yet: the first time you open it, choose
**Open Anyway** in **System Settings › Privacy & Security**.
