# Changelog

What changes in each Archidea release. The section for a version becomes its release notes and what the app shows
under *What's new*.

## [Unreleased]

- **Split view**: up to four tabs side by side in one window, one row in the sidebar. Drag a tab from the sidebar
  onto a page: a card shows whether it goes to that page's left or right. Or choose *Open in Split View* from a tab's
  menu, or press ⌥⌘\ to open a new one beside the page. Each page is a card of its own, and an outline marks the one
  the address bar, back and forward, ⌘W and Find act on: the one you last clicked into. Drag the gap between two pages
  to share the width, double-click it for even shares. In the sidebar every tab of a split has its own close button;
  the last tab left stays as a tab in the split's place. The split's menu separates it, and swaps the sides of two.
  Splits can be pinned and put in folders like tabs.
- The two-finger swipe between spaces keeps up with the fingers and lands in one movement. The sidebar was laid out
  again on every step of the swipe, and the list came back for a moment before the next space slid in.
- Sites get your location. The first time you let one have it, Archidea asks macOS for it; when macOS has location
  off for Archidea, a card says so and opens the setting. Before, macOS was never asked and the site waited in vain.

## [0.2.0] - 2026-10-24

- **More than one window**: ⌘N opens another window on the same sidebar, and ⇧⌘W closes one. Every window has its
  own space, its own tab in front and its own sidebar shown or hidden; the spaces, pins and Today are the same in
  all of them. A page is open in one window at a time: pick a tab another window has in front and this one offers
  to show that window or bring the page over; one open there in the background simply comes over. The windows
  come back where they were at the next launch.
- **Icons for folders and spaces**: about 140 symbols to search through, and emoji: a grid of common ones, and any other
  typed in, pasted or picked from the Character Viewer. A folder's icon is an outline while it's open and filled while
  it's closed; the current space's icon is filled, the others' outlines. Spaces imported from Arc keep their emoji.
- **Cookie banners** go away on their own: Archidea answers them with "reject all" where the site allows it and hides
  the rest. It's on by default; Settings › Privacy and the site controls behind the address switch it off.
- A link opened in a new tab with a middle click or *Open Link in New Tab* opens in the background: you stay on the
  page you're reading. A tab a page opens goes right above that page in Today, in the order they were opened,
  instead of to the top.
- The sidebar slid out over the page stays out while you rename a tab, edit the address, use its menu or a picker
  it opened, instead of sliding away mid-edit.
- Renaming a tab with a long name, or editing a long address, shows the end of it where the caret is.
- The mini window takes clicks and the keyboard: the page, its links and the toolbar's buttons all work, and it
  keeps focus when it opens from another app instead of handing it to the browser window.
- A folder dragged onto another space's button lands among that space's pins. Before, it went into Today and the
  next launch could archive it with every pin inside; a sidebar saved that way is put right on launch.
- Deleting a space that holds tabs asks first.
- Naming a new space created it twice; a card (a name, a question) now takes one answer.
- Two fingers sideways switch spaces anywhere on the sidebar, over the tabs too; before, only over the space bar.
- ⇧⌘T and the start page's *Recently Closed* survive a restart, and a removed pin comes back to its place (its
  folder, its position) instead of into Today.
- Today tabs are archived while Archidea runs, not only at the next launch: the tabs a window has in front and
  tabs playing sound stay. Archived tabs are on ⇧⌘T.
- A private window no longer switches the search engine (and the full-address setting) back to the defaults for
  every window. Settings changed in a private window apply everywhere.
- A pinned tab closed with no open Today tabs moves to another open pin, as 0.1.3 meant it to.
- An update whose download failed is tried again on the next check instead of waiting for a restart; when it
  can't go in where the app is (run from the disk image or Downloads), Archidea says so.
- The diagnostic log no longer holds page titles or addresses, private windows' included, and can't be garbled by
  two threads writing at once.
- Archidea saves the sidebar only when something it keeps changed (not on every page load), writes it off the main
  thread, and clears out icons of tabs that are gone.
- Archidea can open web pages and saved links (.webloc) from Finder.

## [0.1.5] - 2026-10-24

- **Check for Updates** really checks: it used to answer with the last background check's result, so a release
  that came out after it was missed until a restart. Archidea also checks again when you come back to it or
  wake the Mac, and logs each step to the diagnostic log.

- **Start page**: with no tab open, the window shows a search field, the sites you visit most (with their icons)
  and the tabs you closed lately. Start typing anywhere and the address bar opens right over the field with
  your letters in it; right-click a site to take it off. Private windows show no sites.

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
