import AppKit
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
        state = .failed(failure.message)
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
    }

    // MARK: checking

    /// The newest release's manifest. It's a file in the release, not an API call, so checking every few minutes
    /// costs nothing against GitHub's limits; the ETag makes an unchanged answer tiny.
    private var manifestURL: URL? {
        repository.flatMap { URL(string: "https://github.com/\($0)/releases/latest/download/latest.json") }
    }

    func check() {
        guard isEnabled, let manifestURL else { return }
        switch state {
        case .checking, .downloading, .ready: return
        default: break
        }
        state = .checking
        var request = URLRequest(url: manifestURL)
        request.setValue("Archidea/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        request.cachePolicy = .reloadIgnoringLocalCacheData
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async { self?.received(data, response as? HTTPURLResponse, error) }
        }.resume()
    }

    private func received(_ data: Data?, _ response: HTTPURLResponse?, _ error: Error?) {
        guard let response, error == nil else {
            return fail(error.map(Failure.of) ?? .unreachable, "check failed: \(error.map { "\($0)" } ?? "no response")")
        }
        if response.statusCode == 304 { return state = .upToDate }
        guard response.statusCode == 200, let data,
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = manifest["version"] as? String else {
            return fail(.server, "latest.json answered \(response.statusCode)")
        }
        etag = response.value(forHTTPHeaderField: "ETag")
        guard Self.isNewer(version, than: currentVersion) else { return state = .upToDate }
        let os = ProcessInfo.processInfo.operatingSystemVersion
        if let minimum = manifest["minimumSystemVersion"] as? String,
           Self.isNewer(minimum, than: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)") {
            return state = .upToDate
        }
        guard let platform = (manifest["platforms"] as? [String: Any])?["darwin-\(Self.arch)"] as? [String: Any],
              let link = (platform["url"] as? String).flatMap(URL.init(string:)),
              let signature = platform["signature"] as? String else {
            return fail(.server, "latest.json has no darwin-\(Self.arch) update")
        }
        download(version: version, from: link, sha256: platform["sha256"] as? String, signature: signature)
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

    private func download(version: String, from link: URL, sha256: String?, signature: String) {
        state = .downloading(version: version)
        URLSession.shared.downloadTask(with: link) { [weak self] file, _, error in
            guard let self else { return }
            let outcome = file.map { self.unpack($0, version: version, sha256: sha256, signature: signature) }
                ?? .failure(error ?? URLError(.badServerResponse))
            DispatchQueue.main.async {
                switch outcome {
                case let .success(app):
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

/// Checks a minisign signature (the Ed25519 kind made with `minisign -S -l`) against the release key built into
/// the app: the signature over the file, and the global one over the signature and its trusted comment.
enum Minisign {
    static func verify(signature text: String, file: URL, publicKey: String, comment: String) -> Bool {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard lines.count >= 4,
              let signature = Data(base64Encoded: lines[1]), signature.count == 74,
              let keyData = Data(base64Encoded: publicKey), keyData.count == 42,
              signature.prefix(2) == Data("Ed".utf8), Data(signature[2..<10]) == Data(keyData[2..<10]),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: Data(keyData.suffix(32))),
              let contents = try? Data(contentsOf: file, options: .mappedIfSafe),
              key.isValidSignature(Data(signature.suffix(64)), for: contents) else { return false }
        let trusted = lines[2].hasPrefix("trusted comment: ") ? String(lines[2].dropFirst("trusted comment: ".count)) : ""
        guard trusted == comment, let global = Data(base64Encoded: lines[3]), global.count == 64 else { return false }
        return key.isValidSignature(global, for: Data(signature.suffix(64)) + Data(trusted.utf8))
    }
}
