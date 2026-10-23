import AppKit
import CryptoKit
import Security

/// Updates from the project's GitHub releases. The latest release is checked at launch and every few minutes
/// (with its ETag, so an unchanged answer costs nothing against GitHub's limit); a newer one's zip is downloaded,
/// checked against the release's SHA-256 and its code signature (same team as this copy), and unpacked next to
/// the caches. It goes in when the app quits — or right away, with a restart, from the sidebar or the app menu.
///
/// The repository comes from Info.plist (`ArchideaReleases`, "owner/name", set by build.sh). Debug builds don't
/// update themselves unless DRIFT_UPDATES=1, so a development build is never replaced by a release.
final class Updater {
    static let shared = Updater()

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case downloading(version: String)
        case ready(version: String)
        case failed(String)
    }

    private(set) var state = State.idle { didSet { if state != oldValue { observers.forEach { $0(state) } } } }
    private var observers: [(State) -> Void] = []
    private var timer: Timer?
    private var etag: String?
    private var staged: URL?
    private let interval: TimeInterval = 5 * 60
    private static let autoKey = "AutoUpdate"

    let repository = (Bundle.main.object(forInfoDictionaryKey: "ArchideaReleases") as? String).flatMap { $0.contains("/") ? $0 : nil }
    var currentVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }

    /// Installs a downloaded update when the app quits; on by default.
    var installsAutomatically: Bool {
        get { UserDefaults.standard.object(forKey: Self.autoKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.autoKey) }
    }

    var isEnabled: Bool {
        guard repository != nil else { return false }
        #if DEBUG
        return ProcessInfo.processInfo.environment["DRIFT_UPDATES"] == "1"
        #else
        return true
        #endif
    }

    func observe(_ observer: @escaping (State) -> Void) {
        observers.append(observer)
        observer(state)
    }

    func start() {
        guard isEnabled, timer == nil else { return }
        check()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in self?.check() }
    }

    // MARK: checking

    func check() {
        guard isEnabled, let repository else { return }
        switch state {
        case .checking, .downloading, .ready: return
        default: break
        }
        state = .checking
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Archidea/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        request.cachePolicy = .reloadIgnoringLocalCacheData
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async { self?.received(data, response as? HTTPURLResponse, error) }
        }.resume()
    }

    private func received(_ data: Data?, _ response: HTTPURLResponse?, _ error: Error?) {
        guard let response, error == nil else { return state = .failed(error?.localizedDescription ?? "no response") }
        if response.statusCode == 304 { return state = .upToDate }
        guard response.statusCode == 200, let data,
              let release = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = release["tag_name"] as? String else {
            return state = .failed("GitHub answered \(response.statusCode)")
        }
        etag = response.value(forHTTPHeaderField: "ETag")
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        guard Self.isNewer(version, than: currentVersion) else { return state = .upToDate }
        let assets = release["assets"] as? [[String: Any]] ?? []
        guard let asset = assets.first(where: { ($0["name"] as? String)?.hasSuffix(".zip") == true }),
              let link = (asset["browser_download_url"] as? String).flatMap(URL.init(string:)) else {
            return state = .failed("release \(tag) has no .zip")
        }
        let digest = (asset["digest"] as? String).flatMap { $0.hasPrefix("sha256:") ? String($0.dropFirst(7)) : nil }
        download(version: version, from: link, sha256: digest)
    }

    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let parts = { (text: String) in text.split(whereSeparator: { !$0.isNumber }).map { Int($0) ?? 0 } }
        let a = parts(candidate), b = parts(current)
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0, y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: downloading

    private var stagingRoot: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "Archidea").appendingPathComponent("Updates")
    }

    private func download(version: String, from link: URL, sha256: String?) {
        state = .downloading(version: version)
        URLSession.shared.downloadTask(with: link) { [weak self] file, _, error in
            guard let self else { return }
            let outcome = file.map { self.unpack($0, version: version, sha256: sha256) } ?? .failure(error ?? URLError(.badServerResponse))
            DispatchQueue.main.async {
                switch outcome {
                case let .success(app):
                    self.staged = app
                    self.state = .ready(version: version)
                case let .failure(problem):
                    self.state = .failed(String(describing: problem))
                }
            }
        }.resume()
    }

    private struct Problem: Error, CustomStringConvertible { let description: String }

    /// Runs on the download's queue: checksum, unzip, signature.
    private func unpack(_ zip: URL, version: String, sha256: String?) -> Result<URL, Error> {
        let fm = FileManager.default
        if let sha256 {
            guard let handle = try? FileHandle(forReadingFrom: zip) else { return .failure(Problem(description: "can't read the download")) }
            var hasher = SHA256()
            while let chunk = try? handle.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
            let actual = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            guard actual == sha256.lowercased() else { return .failure(Problem(description: "checksum mismatch")) }
        }
        let folder = stagingRoot.appendingPathComponent(version)
        try? fm.removeItem(at: stagingRoot)
        do { try fm.createDirectory(at: folder, withIntermediateDirectories: true) } catch { return .failure(error) }
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", zip.path, folder.path]
        do { try ditto.run() } catch { return .failure(error) }
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0,
              let app = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil))?.first(where: { $0.pathExtension == "app" }) else {
            return .failure(Problem(description: "the zip holds no app"))
        }
        guard Self.isSignedLikeUs(app) else { return .failure(Problem(description: "the new app isn't signed by the same team")) }
        return .success(app)
    }

    /// The new copy must carry a valid signature from the team that signed this one.
    private static func isSignedLikeUs(_ app: URL) -> Bool {
        guard let team = teamIdentifier(of: Bundle.main.bundleURL) else { return false }
        var code: SecStaticCode?
        var requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString("anchor apple generic and certificate leaf[subject.OU] = \"\(team)\"" as CFString, [],
                                             &requirement) == errSecSuccess else { return false }
        let flags = SecCSFlags(rawValue: kSecCSCheckNestedCode | kSecCSStrictValidate)
        return SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess
    }

    private static func teamIdentifier(of app: URL) -> String? {
        var code: SecStaticCode?
        var info: CFDictionary?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
              SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess else { return nil }
        return (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
    }

    // MARK: installing

    /// Swaps the staged copy in once this process has exited, and opens it again if asked.
    private func install(relaunch: Bool) -> Bool {
        guard let staged, FileManager.default.isWritableFile(atPath: Bundle.main.bundleURL.deletingLastPathComponent().path) else { return false }
        let script = """
        while kill -0 "$1" 2>/dev/null; do sleep 0.2; done
        old="$2.previous-$$"
        if mv "$2" "$old" && mv "$3" "$2"; then rm -rf "$old"; else [ -d "$old" ] && [ ! -d "$2" ] && mv "$old" "$2"; fi
        [ "$4" = 1 ] && open "$2"
        """
        let swap = Process()
        swap.executableURL = URL(fileURLWithPath: "/bin/sh")
        swap.arguments = ["-c", script, "archidea-update", String(ProcessInfo.processInfo.processIdentifier),
                          Bundle.main.bundleURL.path, staged.path, relaunch ? "1" : "0"]
        do { try swap.run() } catch { return false }
        self.staged = nil
        return true
    }

    /// From the "Restart to update" button.
    func installNow() {
        guard case .ready = state, install(relaunch: true) else { return }
        NSApp.terminate(nil)
    }

    /// When the app quits on its own.
    func installOnQuit() {
        guard installsAutomatically, case .ready = state else { return }
        _ = install(relaunch: false)
    }
}
