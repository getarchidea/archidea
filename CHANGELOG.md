# Changelog

What changes in each Archidea release. The section for a version becomes its release notes and what the app shows
under *What's new*.

## [Unreleased]

- Clicking into the address while editing it places the caret there. A click on the address bar opened over the
  sidebar closed it and opened it again with everything selected, so only the arrow keys moved the caret.

## [0.4.2] - 2026-10-25

- A tab you've had in front for a while is no longer unloaded the minute you switch away from it: its half hour (or
  whatever Settings says) behind other tabs starts when it leaves the front, not when you picked it. And a page on
  screen that the engine unloaded while the window was covered (short of memory) loads again when you come back.

## [0.4.1] - 2026-10-25

- A tab playing sound shows a speaker in the sidebar, and so does a folder or split holding one; click it to mute
  the tab, and again to let it play. A muted tab shows the speaker crossed out. The tab's menu has *Mute Tab* too.

## [0.4.0] - 2026-10-25

- **Live folders**: *Follow Updates* on a tab (or in the controls behind the address, or File › New Live Folder) turns
  the site into a folder among the pins that fills itself with its latest posts, videos or releases, from the feed the
  site publishes. It's checked every half hour while Archidea runs; what came in since you last looked has a dot, and
  the folder counts it. A post you close doesn't come back, and only the latest 30 stay. The folder's menu checks
  now, marks everything read, or stops following and keeps it as a plain folder.
- **A calmer start page**: the space you're in, a search field and the few keys worth knowing, on a soft wash of the
  space's colour. The most visited sites and recently closed tabs are gone from it: they're in History and on ⇧⌘T,
  and favourites are pinned in the sidebar.
- ⌘P prints the page, with a preview and *Save as PDF*; ⌥⌘P goes straight to the system's print dialog, and ⇧⌘S saves
  the page. The File menu has all three. There was no way to print before.
- The back and forward buttons list the tab's history: hold one, or right-click it, and pick a page; with ⌘ it opens
  in a new tab instead. A middle click or ⌘-click on the button opens the previous (or next) page in a new tab behind
  the one you're on.
- Deleting a folder deletes what's in it, instead of leaving its tabs where it was. One that holds tabs asks first,
  and ⇧⌘T brings them back; a live folder's posts just go.
- Folders open and close faster (about a sixth of a second), starting at once and easing to a stop, instead of
  starting slowly.
- Switching spaces, the sidebar's list and header no longer slide out over the page: they stay inside the sidebar.
- Hover no longer sticks to rows that scrolled away from under the pointer, in the sidebar, the icon and emoji picker
  and the downloads list: it follows the pointer while scrolling.

## [0.3.0] - 2026-10-25

- **Split view**: up to four tabs side by side in one window, one row in the sidebar. Drag a tab from the sidebar
  onto a page: a card shows whether it goes to that page's left or right. Or choose *Open in Split View* from a tab's
  menu, or press ⌥⌘\ to open a new one beside the page. Each page is a card of its own, and an outline marks the one
  the address bar, back and forward, ⌘W and Find act on: the one you last clicked into. Drag the gap between two pages
  to share the width, double-click it for even shares. In the sidebar every tab of a split has its own close button;
  the last tab left stays as a tab in the split's place. The split's menu separates it, and swaps the sides of two.
  Splits can be pinned and put in folders like tabs.
- The two-finger swipe between spaces keeps up with the fingers and lands in one movement. The sidebar was laid out
  again on every step of the swipe, and the list came back for a moment before the next space slid in.
- Location for sites: the first time you let a site have it, Archidea asks macOS too, and macOS shows its own dialog.
  Before, macOS was never asked and the site waited until it gave up. When macOS has location off for Archidea, a
  card says so and opens the setting.

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
