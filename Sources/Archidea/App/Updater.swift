import AppKit
import ArchideaCore
import CryptoKit
import Security

/// Updates from the project's GitHub releases. The newest release's latest.json is checked at launch and every
/// few minutes; a newer version's app zip is downloaded and must carry Archidea's release signature (minisign),
/// match its SHA-256 and carry an intact code signature before it's unpacked next to the caches. It goes in when the app quits — or right away, with a restart, from the sidebar or the app menu.
///
/// The repository and the release key's public half come from Info.plist (`ArchideaReleases`, `ArchideaUpdateKey`,
/// set by build.sh in release builds). Builds without them, and debug builds unless DRIFT_UPDATES=1, never update.
final class Updater {
    static let shared = Updater()

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case downloading(version: String)
        case ready(version: String)
        /// What to tell the user; the technical reason goes to the diagnostic log.
        case failed(String)
    }

    /// Why a check or download didn't work, in words for the user.
    private enum Failure {
        /// No way through to GitHub: offline, a timeout, DNS, a TLS handshake that broke (a flaky network or a
        /// proxy in the way).
        case unreachable
        /// GitHub answered, but not with a release we can read.
        case server
        /// The download didn't verify (signature, checksum, code signature) or wouldn't unpack.
        case damaged

        var message: String {
            switch self {
            case .unreachable: L("update.error.unreachable")
            case .server: L("update.error.server")
            case .damaged: L("update.error.damaged")
            }
        }

        static func of(_ error: Error) -> Failure {
            guard let url = error as? URLError else { return .damaged }
            switch url.code {
            case .badServerResponse, .badURL, .unsupportedURL, .fileDoesNotExist, .zeroByteResource, .cannotDecodeContentData,
                 .cannotDecodeRawData, .cannotParseResponse: return .server
            default: return .unreachable
            }
        }
    }

    private func fail(_ failure: Failure, _ detail: String) {
        Trace.log("updates: \(detail)")
        // The manifest's ETag stood for an answer that came to nothing: the next check reads it in full, or an
        // unchanged manifest would pass for "up to date" and the update that failed would never come again.
        etag = nil
        state = .failed(failure.message)
    }

    private(set) var state = State.idle {
        didSet {
            guard state != oldValue else { return }
            observers.forEach { $0(state) }
            if state != .checking, !answers.isEmpty {
                let waiting = answers
                answers.removeAll()
                waiting.forEach { $0(state) }
            }
        }
    }
    private var observers: [(State) -> Void] = []
    private var timer: Timer?
    private var etag: String?
    private var staged: URL?
    private let interval: TimeInterval = {
        #if DRIFT_DEV
        if let seconds = ProcessInfo.processInfo.environment["DRIFT_UPDATE_INTERVAL"].flatMap(TimeInterval.init) { return seconds }
        #endif
        return 5 * 60
    }()
    private static let autoKey = "AutoUpdate"

    let repository = (Bundle.main.object(forInfoDictionaryKey: "ArchideaReleases") as? String).flatMap { $0.contains("/") ? $0 : nil }
    var currentVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }

    /// Installs a downloaded update when the app quits; on by default.
    var installsAutomatically: Bool {
        get { UserDefaults.standard.object(forKey: Self.autoKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.autoKey) }
    }

    private var updateKey: String? {
        (Bundle.main.object(forInfoDictionaryKey: "ArchideaUpdateKey") as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The Mac's architecture as release files name it.
    private static var arch: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "amd64"
        #endif
    }

    var isEnabled: Bool {
        guard repository != nil, updateKey != nil else { return false }
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
        // The timer stands still while the Mac sleeps, and a check that failed on a bad network waits for the next
        // round: coming back to the app or waking the Mac checks again once the last check is older than a round.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.checkIfStale()
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.checkIfStale()
        }
    }

    private var lastCheck = Date.distantPast

    private func checkIfStale() {
        guard Date().timeIntervalSince(lastCheck) > interval else { return }
        check()
    }

    // MARK: checking

    /// The newest release's manifest. It's a file in the release, not an API call, so checking every few minutes
    /// costs nothing against GitHub's limits; the ETag makes an unchanged answer tiny.
    private var manifestURL: URL? {
        repository.flatMap { URL(string: "https://github.com/\($0)/releases/latest/download/latest.json") }
    }

    /// Waiting for the answer to a check the user asked for.
    private var answers: [(State) -> Void] = []

    /// Checks now, from the user (the menu, Settings), and calls back with what this check found — never with
    /// what an earlier one did. A download already under way or done is the answer as it is.
    func checkNow(then answer: @escaping (State) -> Void) {
        switch state {
        case .downloading, .ready: return answer(state)
        case .checking: answers.append(answer)
        default:
            answers.append(answer)
            check(fresh: true)
        }
    }

    /// `fresh` skips the ETag: the user asked, so the manifest is read in full whatever came before.
    func check(fresh: Bool = false) {
        guard isEnabled, let manifestURL else { return }
        switch state {
        case .checking, .downloading, .ready: return
        default: break
        }
        state = .checking
        lastCheck = Date()
        Trace.log("updates: checking\(fresh ? " (asked)" : "") for a version after \(currentVersion)")
        var request = URLRequest(url: manifestURL)
        request.setValue("Archidea/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        if let etag, !fresh { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 30
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async { self?.received(data, response as? HTTPURLResponse, error) }
        }.resume()
    }

    private func received(_ data: Data?, _ response: HTTPURLResponse?, _ error: Error?) {
        guard let response, error == nil else {
            return fail(error.map(Failure.of) ?? .unreachable, "check failed: \(error.map { "\($0)" } ?? "no response")")
        }
        if response.statusCode == 304 {
            Trace.log("updates: manifest unchanged")
            return state = .upToDate
        }
        guard response.statusCode == 200, let data,
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = manifest["version"] as? String else {
            return fail(.server, "latest.json answered \(response.statusCode)")
        }
        etag = response.value(forHTTPHeaderField: "ETag")
        Trace.log("updates: newest release is \(version)")
        guard ReleaseVersion.isNewer(version, than: currentVersion) else { return state = .upToDate }
        let os = ProcessInfo.processInfo.operatingSystemVersion
        if let minimum = manifest["minimumSystemVersion"] as? String,
           ReleaseVersion.isNewer(minimum, than: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)") {
            return state = .upToDate
        }
        guard let platform = (manifest["platforms"] as? [String: Any])?["darwin-\(Self.arch)"] as? [String: Any],
              let link = (platform["url"] as? String).flatMap(URL.init(string:)),
              let signature = platform["signature"] as? String else {
            return fail(.server, "latest.json has no darwin-\(Self.arch) update")
        }
        download(version: version, from: link, sha256: platform["sha256"] as? String, signature: signature)
    }

    // MARK: downloading

    private var stagingRoot: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "Archidea").appendingPathComponent("Updates")
    }

    private func download(version: String, from link: URL, sha256: String?, signature: String) {
        Trace.log("updates: downloading \(version)")
        state = .downloading(version: version)
        URLSession.shared.downloadTask(with: link) { [weak self] file, _, error in
            guard let self else { return }
            let outcome = file.map { self.unpack($0, version: version, sha256: sha256, signature: signature) }
                ?? .failure(error ?? URLError(.badServerResponse))
            DispatchQueue.main.async {
                switch outcome {
                case let .success(app):
                    Trace.log("updates: \(version) is ready")
                    self.staged = app
                    self.state = .ready(version: version)
                case let .failure(problem):
                    self.fail(problem is Problem ? .damaged : Failure.of(problem), "update \(version): \(problem)")
                }
            }
        }.resume()
    }

    private struct Problem: Error, CustomStringConvertible { let description: String }

    /// Runs on the download's queue: release signature, checksum, unzip, code signature.
    private func unpack(_ zip: URL, version: String, sha256: String?, signature: String) -> Result<URL, Error> {
        let fm = FileManager.default
        // The trusted comment ties the signature to this version and file, so an older signed file can't be passed off.
        let comment = "archidea v\(version) archidea-darwin-\(Self.arch).app.zip"
        guard let key = updateKey, Minisign.verify(signature: signature, file: zip, publicKey: key, comment: comment) else {
            return .failure(Problem(description: "the update isn't signed with Archidea's release key"))
        }
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
        guard Self.hasValidSignature(app) else { return .failure(Problem(description: "the new app's code signature is broken")) }
        return .success(app)
    }

    /// The new copy's code signature must be intact (the release key above is what says it's ours).
    private static func hasValidSignature(_ app: URL) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else { return false }
        return SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckNestedCode | kSecCSStrictValidate), nil) == errSecSuccess
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

    /// From the "Restart to update" button. False when the update can't go in where the app is (a copy run from
    /// the disk image or straight from Downloads, which macOS keeps read-only): the app keeps running.
    @discardableResult
    func installNow() -> Bool {
        guard case .ready = state else { return false }
        guard install(relaunch: true) else {
            Trace.log("updates: can't replace the app at its location")
            return false
        }
        NSApp.terminate(nil)
        return true
    }

    /// When the app quits on its own.
    func installOnQuit() {
        guard installsAutomatically, case .ready = state else { return }
        _ = install(relaunch: false)
    }
}
