import Foundation

/// Chrome's own services that ArdiaCore exports as plain C calls (`ac_*`): JSON arguments in, JSON reply out.
/// The functions live in the engine framework and are found with dlsym.
enum EngineCall {
    private typealias Reply = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> Void
    private typealias Call = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?, Reply, UnsafeMutableRawPointer?) -> Void

    /// One call's completion; it runs once, on the main queue: with the reply, or with nil when a timeout ran out first.
    private final class Pending {
        private let completion: ([String: Any]?) -> Void
        private var finished = false
        init(_ completion: @escaping ([String: Any]?) -> Void) { self.completion = completion }

        func finish(_ reply: [String: Any]?) {
            guard !finished else { return }
            finished = true
            completion(reply)
        }
    }

    static func exists(_ name: String) -> Bool {
        dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) != nil
    }

    /// Calls `name` for `profile`; the completion runs on the main queue with the parsed reply, or nil on failure.
    /// With a `timeout` it runs with nil once that passes without a reply (a step of an import mustn't hang it).
    static func call(_ name: String, profile: ArdiaCoreProfile, args: [String: Any] = [:], timeout: TimeInterval? = nil,
                     completion: @escaping ([String: Any]?) -> Void = { _ in }) {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name),
              let data = try? JSONSerialization.data(withJSONObject: args),
              let json = String(data: data, encoding: .utf8) else {
            Trace.log("engine call \(name): unavailable")
            return completion(nil)
        }
        let call = unsafeBitCast(symbol, to: Call.self)
        let pending = Pending(completion)
        if let timeout {
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                pending.finish(nil)
            }
        }
        let context = Unmanaged.passRetained(pending).toOpaque()
        let reply: Reply = { context, json in
            guard let context else { return }
            let pending = Unmanaged<Pending>.fromOpaque(context).takeRetainedValue()
            let text = json.map { String(cString: $0) } ?? ""
            let parsed = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
            DispatchQueue.main.async { pending.finish(parsed) }
        }
        profile.path.withCString { path in
            json.withCString { args in call(path, args, reply, context) }
        }
    }

    /// Like `call`, for arguments holding secrets (passwords, cookie values): a NUL-terminated JSON buffer that is
    /// copied once, handed to the engine (which parses it before returning) and zeroed straight after.
    static func callSecret(_ name: String, profile: ArdiaCoreProfile, json bytes: UnsafeRawBufferPointer, timeout: TimeInterval? = nil,
                           completion: @escaping ([String: Any]?) -> Void) {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name), let base = bytes.baseAddress,
              bytes.count > 0, bytes[bytes.count - 1] == 0 else { return completion(nil) }
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bytes.count, alignment: 1)
        buffer.copyMemory(from: base, byteCount: bytes.count)
        defer {
            memset_s(buffer, bytes.count, 0, bytes.count)
            buffer.deallocate()
        }
        let call = unsafeBitCast(symbol, to: Call.self)
        let pending = Pending(completion)
        if let timeout {
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                pending.finish(nil)
            }
        }
        let context = Unmanaged.passRetained(pending).toOpaque()
        let reply: Reply = { context, json in
            guard let context else { return }
            let pending = Unmanaged<Pending>.fromOpaque(context).takeRetainedValue()
            let text = json.map { String(cString: $0) } ?? ""
            let parsed = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
            DispatchQueue.main.async { pending.finish(parsed) }
        }
        profile.path.withCString { path in call(path, buffer.assumingMemoryBound(to: CChar.self), reply, context) }
    }
}

/// Events the engine pushes on its own (`downloads.changed`, …): a topic and a JSON payload, on the main thread.
/// The engine takes one sink; handlers register here by topic.
enum EngineEvents {
    private typealias Sink = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Void
    private typealias SetSink = @convention(c) (Sink, UnsafeMutableRawPointer?) -> Void

    private static var handlers: [String: [([String: Any]) -> Void]] = [:]
    private static var installed = false

    static func on(_ topic: String, _ handler: @escaping ([String: Any]) -> Void) {
        install()
        handlers[topic, default: []].append(handler)
    }

    private static func install() {
        guard !installed, let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "ac_engine_set_event_sink") else { return }
        installed = true
        let sink: Sink = { _, topic, json in
            guard let topic else { return }
            let name = String(cString: topic)
            let text = json.map { String(cString: $0) } ?? "{}"
            let payload = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
            let deliver: () -> Void = { EngineEvents.handlers[name]?.forEach { $0(payload) } }
            if Thread.isMainThread { deliver() } else { DispatchQueue.main.async(execute: deliver) }
        }
        unsafeBitCast(symbol, to: SetSink.self)(sink, nil)
    }
}
