import Foundation

/// Chrome's own services that ArdiaCore exports as plain C calls (`ac_*`): JSON arguments in, JSON reply out.
/// The functions live in the engine framework and are found with dlsym.
enum EngineCall {
    private typealias Reply = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> Void
    private typealias Call = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?, Reply, UnsafeMutableRawPointer?) -> Void

    private final class Pending {
        let completion: ([String: Any]?) -> Void
        init(_ completion: @escaping ([String: Any]?) -> Void) { self.completion = completion }
    }

    static func exists(_ name: String) -> Bool {
        dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) != nil
    }

    /// Calls `name` for `profile`; the completion runs on the main queue with the parsed reply, or nil on failure.
    static func call(_ name: String, profile: ArdiaCoreProfile, args: [String: Any] = [:], completion: @escaping ([String: Any]?) -> Void = { _ in }) {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name),
              let data = try? JSONSerialization.data(withJSONObject: args),
              let json = String(data: data, encoding: .utf8) else {
            Trace.log("engine call \(name): unavailable")
            return completion(nil)
        }
        let call = unsafeBitCast(symbol, to: Call.self)
        let context = Unmanaged.passRetained(Pending(completion)).toOpaque()
        let reply: Reply = { context, json in
            guard let context else { return }
            let pending = Unmanaged<Pending>.fromOpaque(context).takeRetainedValue()
            let text = json.map { String(cString: $0) } ?? ""
            let parsed = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
            DispatchQueue.main.async { pending.completion(parsed) }
        }
        profile.path.withCString { path in
            json.withCString { args in call(path, args, reply, context) }
        }
    }

    /// Like `call`, for arguments holding secrets (passwords, cookie values): a NUL-terminated JSON buffer that is
    /// copied once, handed to the engine (which parses it before returning) and zeroed straight after.
    static func callSecret(_ name: String, profile: ArdiaCoreProfile, json bytes: UnsafeRawBufferPointer,
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
        let context = Unmanaged.passRetained(Pending(completion)).toOpaque()
        let reply: Reply = { context, json in
            guard let context else { return }
            let pending = Unmanaged<Pending>.fromOpaque(context).takeRetainedValue()
            let text = json.map { String(cString: $0) } ?? ""
            let parsed = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
            DispatchQueue.main.async { pending.completion(parsed) }
        }
        profile.path.withCString { path in call(path, buffer.assumingMemoryBound(to: CChar.self), reply, context) }
    }
}
