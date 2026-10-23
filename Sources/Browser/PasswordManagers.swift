import Foundation

/// Password managers reach their browser extensions over Chrome's native messaging: 1Password, Bitwarden,
/// Proton Pass, KeePassXC. Apple Passwords isn't among them: macOS only lets its helper run under browsers Apple
/// approves (a parent launch constraint), so its passwords come in through a CSV export instead. Chrome finds the hosts'
/// manifests in Google's folders; the engine looks in its own profile folder, so Drift copies the usable ones
/// there. Hosts it put there and that are gone since are removed again.
enum PasswordManagers {
    struct Manager {
        let name: String
        let host: String
        let extensionID: String
        /// A manifest written by Drift when the app is installed but registered no host for Chrome.
        let fallback: [String: Any]?
    }

    static let all: [Manager] = [
        Manager(name: "1Password", host: "com.1password.1password", extensionID: "aeblfdkhhhdcdjpifhhbdiojplfjncoa", fallback: [
            "name": "com.1password.1password", "description": "1Password BrowserSupport", "type": "stdio",
            "path": "/Applications/1Password.app/Contents/Library/LoginItems/1Password Browser Helper.app/Contents/MacOS/1Password-BrowserSupport",
            "allowed_origins": ["chrome-extension://hjlinigoblmkhjejkmbegnoaljkphmgo/", "chrome-extension://gejiddohjgogedgjnonbofjigllpkmbf/",
                                "chrome-extension://khgocmkkpikpnmmkgmdnfckapcdkgfaf/", "chrome-extension://aeblfdkhhhdcdjpifhhbdiojplfjncoa/",
                                "chrome-extension://dppgmdbiimibapkepcbdbmkaabgiofem/"],
        ]),
        Manager(name: "Bitwarden", host: "com.8bit.bitwarden", extensionID: "nngceckbapebfimnlniiiahkandclblb", fallback: [
            "name": "com.8bit.bitwarden", "description": "Bitwarden desktop <-> browser bridge", "type": "stdio",
            "path": "/Applications/Bitwarden.app/Contents/MacOS/desktop_proxy",
            "allowed_origins": ["chrome-extension://nngceckbapebfimnlniiiahkandclblb/", "chrome-extension://hccnnhgbibccigepcmlgppchkpfdophk/",
                                "chrome-extension://jbkfoedolllekgbhcbcoahefnbanhhlh/", "chrome-extension://ccnckbpmaceehanjmeomladnmlffdjgn/"],
        ]),
        Manager(name: "Proton Pass", host: "me.proton.pass.nm", extensionID: "ghmbeldphafepmbegfdlkpapadhbakde", fallback: [
            "name": "me.proton.pass.nm", "description": "Proton Pass host for native messaging with the desktop app", "type": "stdio",
            "path": "/Applications/Proton Pass.app/Contents/Resources/assets/proton_pass_nm_host",
            "allowed_origins": ["chrome-extension://ghmbeldphafepmbegfdlkpapadhbakde/", "chrome-extension://hlaiofkbmjenhgeinjlmkafaipackfjh/",
                                "chrome-extension://gcllgfdnfnllodcaambdaknbipemelie/"],
        ]),
        Manager(name: "KeePassXC", host: "org.keepassxc.keepassxc_browser", extensionID: "oboonakemofpalcgghocfoadofidjkkk", fallback: [
            "name": "org.keepassxc.keepassxc_browser", "description": "KeePassXC integration with native messaging support", "type": "stdio",
            "path": "/Applications/KeePassXC.app/Contents/MacOS/keepassxc-proxy",
            "allowed_origins": ["chrome-extension://pdffhmdngciaglkoonimfcmckehcpafo/", "chrome-extension://oboonakemofpalcgghocfoadofidjkkk/"],
        ]),
    ]

    private static var chromeFolders: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            URL(fileURLWithPath: "/Library/Google/Chrome/NativeMessagingHosts"),
            home.appendingPathComponent("Library/Application Support/Google/Chrome/NativeMessagingHosts"),
            home.appendingPathComponent("Library/Application Support/Chromium/NativeMessagingHosts"),
        ]
    }

    private static let managedList = ".drift-managed.json"

    private static func usable(_ manifest: [String: Any]?, name: String? = nil) -> Bool {
        guard let manifest, let path = manifest["path"] as? String, let host = manifest["name"] as? String,
              manifest["type"] as? String == "stdio", manifest["allowed_origins"] is [Any] else { return false }
        if let name, host != name { return false }
        return path.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: path)
    }

    private static func read(_ url: URL) -> [String: Any]? {
        (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    /// Every host a Chrome profile would find, plus the known managers' own when they registered none.
    static func installedHosts() -> [String: Data] {
        var hosts: [String: Data] = [:]
        for folder in chromeFolders {
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            for file in files where file.pathExtension == "json" {
                let host = file.deletingPathExtension().lastPathComponent
                guard hosts[host] == nil, let data = try? Data(contentsOf: file),
                      usable((try? JSONSerialization.jsonObject(with: data)) as? [String: Any], name: host) else { continue }
                hosts[host] = data
            }
        }
        for manager in all where hosts[manager.host] == nil {
            if let fallback = manager.fallback, usable(fallback, name: manager.host),
               let data = try? JSONSerialization.data(withJSONObject: fallback, options: [.prettyPrinted, .withoutEscapingSlashes]) {
                hosts[manager.host] = data
            }
        }
        return hosts
    }

    /// Mirrors the hosts into `<profile>/NativeMessagingHosts`, leaving any the user put there alone.
    static func sync(into userDataDir: URL) {
        let fm = FileManager.default
        let dir = userDataDir.appendingPathComponent("NativeMessagingHosts")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let listURL = dir.appendingPathComponent(managedList)
        let previous = Set((try? JSONSerialization.jsonObject(with: Data(contentsOf: listURL))) as? [String] ?? [])
        let hosts = installedHosts().filter { $0.key != "com.apple.passwordmanager" }
        for (host, data) in hosts {
            let target = dir.appendingPathComponent("\(host).json")
            if (try? Data(contentsOf: target)) != data { try? data.write(to: target, options: .atomic) }
        }
        for host in previous.subtracting(hosts.keys) {
            try? fm.removeItem(at: dir.appendingPathComponent("\(host).json"))
        }
        if let data = try? JSONSerialization.data(withJSONObject: Array(hosts.keys).sorted()) { try? data.write(to: listURL, options: .atomic) }
        Trace.log("native messaging hosts: \(hosts.keys.sorted().joined(separator: ", "))")
    }

    /// Whether the manager's app is on this Mac, so its extension can talk to it.
    static func isAvailable(_ manager: Manager) -> Bool {
        installedHosts()[manager.host] != nil
    }
}
