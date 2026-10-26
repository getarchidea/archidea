import Foundation
import ArchideaCore

/// The AI service the person connected in Settings: its key, and the requests the features send to it. The key is
/// kept in a file only this user can read, in the browser's data folder, never in the sidebar's state; without one,
/// a browser started from a terminal uses that shell's ANTHROPIC_API_KEY or OPENAI_API_KEY.
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
        return ProcessInfo.processInfo.environment[settings.provider.environmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
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

    /// Connected: a key, or a service of one's own that needs none (a local Ollama), and a model to ask.
    var isConnected: Bool {
        guard !settings.resolvedModel.isEmpty else { return false }
        return !key.isEmpty || (settings.provider == .openAI && !settings.baseURL.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    private func urlRequest(_ request: AIRequest, stream: Bool) throws -> URLRequest {
        guard isConnected else { throw key.isEmpty ? AIError.noKey : AIError.noModel }
        return try AIWire.urlRequest(request, settings: settings, key: key, stream: stream)
    }

    /// The whole answer at once (the background features, which want JSON).
    func complete(_ request: AIRequest) async throws -> String {
        let provider = settings.provider
        let urlRequest = try urlRequest(request, stream: false)
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: urlRequest)
        } catch let error as URLError {
            throw AIError(error)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw AIWire.error(status: status, body: data) }
        return try AIWire.text(from: data, provider: provider)
    }

    /// The answer as it's written (Ask AI). Ends with an `AIError` when it can't be had.
    func stream(_ request: AIRequest) -> AsyncThrowingStream<String, Error> {
        let provider = settings.provider
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
                        switch AIWire.event(fromLine: payload, provider: provider) {
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
