import Foundation
import ArchideaCore

/// The AI service the person connected in Settings: its key, and the requests the features send to it. Each service's
/// key is kept in a file only this user can read, in the browser's data folder, never in the sidebar's state; without
/// one, a browser started from a terminal uses that shell's (ANTHROPIC_API_KEY, OPENAI_API_KEY and so on).
final class AIService {
    static let shared = AIService()

    /// Settings → AI, as the windows last applied them.
    var settings = AISettings()

    private var keyFile: URL { Paths.root.appendingPathComponent("ai-\(settings.provider.rawValue).key") }

    /// The key entered in Settings for the current provider, if any (not the environment's).
    var storedKey: String {
        (try? String(contentsOf: keyFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    var key: String {
        let stored = storedKey
        if !stored.isEmpty { return stored }
        let name = settings.provider.environmentKey
        guard !name.isEmpty else { return "" }
        return ProcessInfo.processInfo.environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// Whether the key comes from the environment rather than Settings.
    var keyFromEnvironment: Bool { storedKey.isEmpty && !key.isEmpty }

    func setKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try? FileManager.default.removeItem(at: keyFile)
            return
        }
        FileManager.default.createFile(atPath: keyFile.path, contents: Data(trimmed.utf8), attributes: [.posixPermissions: 0o600])
    }

    /// Connected: a key (a server on this Mac, or one's own, needs none) and a model to ask.
    var isConnected: Bool {
        guard !settings.resolvedModel.isEmpty, !settings.resolvedBaseURL.isEmpty else { return false }
        return !key.isEmpty || settings.provider.isLocal || settings.provider == .custom
    }

    /// The service's models, by provider and address, once asked for.
    private var modelLists: [String: [String]] = [:]

    func cachedModels() -> [String]? { modelLists[settings.provider.rawValue + settings.resolvedBaseURL] }

    /// The models the service offers (needs the key, except on this Mac).
    func models() async throws -> [String] {
        let cacheKey = settings.provider.rawValue + settings.resolvedBaseURL
        if let list = modelLists[cacheKey] { return list }
        let request = try AIWire.modelsRequest(settings: settings, key: key)
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let error as URLError {
            throw AIError(error)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw AIWire.error(status: status, body: data) }
        let list = AIWire.models(from: data)
        modelLists[cacheKey] = list
        return list
    }

    private func urlRequest(_ request: AIRequest, stream: Bool) throws -> URLRequest {
        guard isConnected else { throw settings.resolvedModel.isEmpty ? AIError.noModel : AIError.noKey }
        return try AIWire.urlRequest(request, settings: settings, key: key, stream: stream)
    }

    /// The whole answer at once (the background features, which want JSON).
    func complete(_ request: AIRequest) async throws -> String {
        let api = settings.provider.api
        let urlRequest = try urlRequest(request, stream: false)
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: urlRequest)
        } catch let error as URLError {
            throw AIError(error)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw AIWire.error(status: status, body: data) }
        return try AIWire.text(from: data, api: api)
    }

    /// The answer as it's written (Ask AI). Ends with an `AIError` when it can't be had.
    func stream(_ request: AIRequest) -> AsyncThrowingStream<String, Error> {
        let api = settings.provider.api
        let built = Result { try urlRequest(request, stream: true) }
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let urlRequest = try built.get()
                    let (bytes, response) = try await URLSession.shared.bytes(for: urlRequest)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard (200..<300).contains(status) else {
                        var body = Data()
                        for try await byte in bytes { body.append(byte) }
                        throw AIWire.error(status: status, body: body)
                    }
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        switch AIWire.event(fromLine: payload, api: api) {
                        case let .text(text)?: continuation.yield(text)
                        case .done?: continuation.finish()
                            return
                        case let .failed(error)?: throw error
                        case nil: break
                        }
                    }
                    continuation.finish()
                } catch let error as URLError {
                    continuation.finish(throwing: error.code == .cancelled ? CancellationError() : AIError(error))
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
