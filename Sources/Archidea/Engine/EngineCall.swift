import ArdiaCore
import Foundation

/// The engine's own C functions (`ac_*`) the app calls. Their arguments and replies are written down once, as types,
/// in `EngineServices`; nothing else names a function by its string.
enum EngineFunction: String {
    case historyQuery = "ac_history_query"
    case historyImport = "ac_history_import"
    case bookmarksApply = "ac_bookmarks_apply"
    case faviconsGet = "ac_favicons_get"
    case faviconsSet = "ac_favicons_set"
    case downloadsList = "ac_downloads_list"
    case downloadsPause = "ac_downloads_pause"
    case downloadsResume = "ac_downloads_resume"
    case downloadsCancel = "ac_downloads_cancel"
    case downloadsKeep = "ac_downloads_keep"
    case downloadsRemove = "ac_downloads_remove"
    case siteSettingsGet = "ac_site_settings_get"
    case siteSettingsSet = "ac_site_settings_set"
    case siteDataClear = "ac_site_data_clear"
    case passwordsAdd = "ac_passwords_add"
    case cookiesImport = "ac_cookies_import"
}

/// Why a call to the engine came back without what it was asked for.
enum EngineFailure: Error, CustomStringConvertible {
    /// This engine build has no such function.
    case unavailable
    /// No reply before the call's timeout.
    case timedOut
    /// The engine answered with an error of its own.
    case refused(String)
    /// The reply doesn't read as what the function returns.
    case unreadable(String)

    var description: String {
        switch self {
        case .unavailable: "unavailable"
        case .timedOut: "no reply in time"
        case let .refused(message): "refused: \(message)"
        case let .unreadable(detail): "unreadable reply: \(detail)"
        }
    }
}

/// A reply with nothing in it to read: the call is done.
struct EngineDone: Decodable {}

/// Moves calls to Chrome's services that ArdiaCore exports as plain C functions: JSON arguments in, a JSON reply out,
/// on the main queue. The functions live in the engine framework and are found with dlsym. Callers use the typed
/// calls in `EngineServices`.
enum EngineCall {
    private typealias Callback = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> Void
    private typealias Call = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?, Callback, UnsafeMutableRawPointer?) -> Void

    /// One call's completion; it runs once, on the main queue: with the reply's bytes, or with nil when a timeout ran
    /// out first.
    private final class Pending {
        private let completion: (Data?) -> Void
        private var finished = false
        init(_ completion: @escaping (Data?) -> Void) { self.completion = completion }

        func finish(_ reply: Data?) {
            guard !finished else { return }
            finished = true
            completion(reply)
        }
    }

    static func exists(_ function: EngineFunction) -> Bool {
        dlsym(UnsafeMutableRawPointer(bitPattern: -2), function.rawValue) != nil
    }

    /// Calls `function` for `profile` with `args` encoded as JSON, and decodes its reply as `Reply`.
    /// With a `timeout` it fails with `.timedOut` once that passes without a reply (a step of an import mustn't hang).
    static func request<Reply: Decodable>(_ function: EngineFunction, profile: ArdiaCoreProfile, args: some Encodable,
                                          timeout: TimeInterval? = nil, completion: @escaping (Result<Reply, EngineFailure>) -> Void) {
        guard let data = try? JSONEncoder().encode(args) else { return completion(.failure(.unreadable("arguments don't encode"))) }
        var text = data
        text.append(0)
        text.withUnsafeBytes { bytes in send(function, profile: profile, json: bytes, timeout: timeout, completion: completion) }
    }

    /// Like `request`, for arguments holding secrets (passwords, cookie values): a NUL-terminated JSON buffer that is
    /// copied once, handed to the engine (which parses it before returning) and zeroed straight after.
    static func requestSecret<Reply: Decodable>(_ function: EngineFunction, profile: ArdiaCoreProfile, json bytes: UnsafeRawBufferPointer,
                                                timeout: TimeInterval? = nil, completion: @escaping (Result<Reply, EngineFailure>) -> Void) {
        send(function, profile: profile, json: bytes, timeout: timeout, completion: completion)
    }

    private static func send<Reply: Decodable>(_ function: EngineFunction, profile: ArdiaCoreProfile, json bytes: UnsafeRawBufferPointer,
                                               timeout: TimeInterval?, completion: @escaping (Result<Reply, EngineFailure>) -> Void) {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), function.rawValue) else {
            Trace.log("engine call \(function.rawValue): unavailable")
            return completion(.failure(.unavailable))
        }
        guard let base = bytes.baseAddress, bytes.count > 0, bytes[bytes.count - 1] == 0 else {
            return completion(.failure(.unreadable("arguments aren't NUL-terminated")))
        }
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bytes.count, alignment: 1)
        buffer.copyMemory(from: base, byteCount: bytes.count)
        defer {
            memset_s(buffer, bytes.count, 0, bytes.count)
            buffer.deallocate()
        }
        let call = unsafeBitCast(symbol, to: Call.self)
        let pending = Pending { reply in completion(decode(reply)) }
        if let timeout {
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                pending.finish(nil)
            }
        }
        let context = Unmanaged.passRetained(pending).toOpaque()
        profile.path.withCString { path in call(path, buffer.assumingMemoryBound(to: CChar.self), replied, context) }
    }

    /// Where the engine replies to every call: `context` is the call's `Pending`, retained until now.
    private static let replied: Callback = { context, json in
        guard let context else { return }
        let pending = Unmanaged<Pending>.fromOpaque(context).takeRetainedValue()
        let data = json.map { Data(String(cString: $0).utf8) } ?? Data()
        DispatchQueue.main.async { pending.finish(data) }
    }

    /// A reply as `Reply`; an object with an "error" in it is the engine saying no, whatever else it holds.
    private static func decode<Reply: Decodable>(_ data: Data?) -> Result<Reply, EngineFailure> {
        guard let reply = data else { return .failure(.timedOut) }
        // An empty reply is a call with nothing to say.
        let data = reply.isEmpty ? Data("{}".utf8) : reply
        let decoder = JSONDecoder()
        if let refusal = try? decoder.decode(Refusal.self, from: data), let message = refusal.message {
            return .failure(.refused(message))
        }
        do {
            return .success(try decoder.decode(Reply.self, from: data))
        } catch {
            return .failure(.unreadable("\(error)"))
        }
    }

    private struct Refusal: Decodable {
        let message: String?

        private enum CodingKeys: String, CodingKey { case error }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            if try !c.contains(.error) || c.decodeNil(forKey: .error) {
                message = nil
            } else {
                message = (try? c.decode(String.self, forKey: .error)) ?? "error"
            }
        }
    }
}

/// Events the engine pushes on its own (`downloads.changed`, …): a topic and a JSON payload, on the main thread.
/// The engine takes one sink; handlers register here by topic, each for the payload type it reads.
enum EngineEvents {
    private typealias Sink = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Void
    private typealias SetSink = @convention(c) (Sink, UnsafeMutableRawPointer?) -> Void

    private static var handlers: [String: [(Data) -> Void]] = [:]
    private static var installed = false

    /// Calls `handler` with every `topic` event whose payload reads as `Payload`; one that doesn't is logged.
    static func on<Payload: Decodable>(_ topic: String, as type: Payload.Type, _ handler: @escaping (Payload) -> Void) {
        install()
        handlers[topic, default: []].append { data in
            do {
                handler(try JSONDecoder().decode(Payload.self, from: data))
            } catch {
                Trace.log("engine event \(topic): unreadable payload (\(error))")
            }
        }
    }

    private static func install() {
        guard !installed, let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "ac_engine_set_event_sink") else { return }
        installed = true
        let sink: Sink = { _, topic, json in
            guard let topic else { return }
            let name = String(cString: topic)
            let data = Data((json.map { String(cString: $0) } ?? "{}").utf8)
            let deliver: () -> Void = { EngineEvents.handlers[name]?.forEach { $0(data) } }
            if Thread.isMainThread { deliver() } else { DispatchQueue.main.async(execute: deliver) }
        }
        unsafeBitCast(symbol, to: SetSink.self)(sink, nil)
    }
}
