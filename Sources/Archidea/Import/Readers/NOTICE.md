# Import readers

Readers for other browsers' data (Chromium family, Arc, Dia, Firefox, Safari), taken from
https://github.com/mantrakp04/ardia (packages/import/ios/Core at 38befbb),
Copyright 2026 Mantra Patel, licensed under the Apache License 2.0 (LICENSE in this folder).

Changes: files are grouped by browser and renamed for what they read (Model.swift → Shared/ImportModel.swift,
ArcSidebar.swift → Arc/ArcSpaces.swift, DiaTabs.swift → Dia/DiaOpenTabs.swift, DiaAppleEvents.swift →
Dia/DiaScripting.swift, ChromiumCrypto.swift → Chromium/ChromiumKeys.swift, Firefox.swift → Firefox/FirefoxProfile.swift,
SafariDirect.swift → Safari/SafariLibrary.swift, SafariExport.swift → Safari/SafariExportArchive.swift, Discovery.swift →
Shared/BrowserDiscovery.swift, NetscapeBookmarks.swift → Shared/BookmarksHTML.swift, Wire.swift → Shared/CookieWire.swift);
ArcSidebar is called ArcSpaces; user-facing messages don't name the original app; ImportError reads as its message.
