import Foundation

/// Who answers. Each service comes filled in: its address, a cheap model that does the job (an alias that follows
/// the service's newest where it has one) and where a terminal keeps its key; Settings can change the model and the
/// address. All but Anthropic speak OpenAI's chat completions.
public enum AIProvider: String, Codable, CaseIterable {
    case anthropic, openAI, gemini, openRouter, groq, mistral, deepSeek, ollama, lmStudio, custom

    /// The two ways of asking.
    public enum API { case anthropic, openAI }

    public var api: API { self == .anthropic ? .anthropic : .openAI }

    public var name: String {
        switch self {
        case .anthropic: return "Anthropic (Claude)"
        case .openAI: return "OpenAI (ChatGPT)"
        case .gemini: return "Google (Gemini)"
        case .openRouter: return "OpenRouter"
        case .groq: return "Groq (Llama)"
        case .mistral: return "Mistral"
        case .deepSeek: return "DeepSeek"
        case .ollama: return L("ai.provider.ollama")
        case .lmStudio: return L("ai.provider.lmStudio")
        case .custom: return L("ai.provider.custom")
        }
    }

    public var defaultBaseURL: String {
        switch self {
        case .anthropic: return "https://api.anthropic.com"
        case .openAI: return "https://api.openai.com/v1"
        case .gemini: return "https://generativelanguage.googleapis.com/v1beta/openai"
        case .openRouter: return "https://openrouter.ai/api/v1"
        case .groq: return "https://api.groq.com/openai/v1"
        case .mistral: return "https://api.mistral.ai/v1"
        case .deepSeek: return "https://api.deepseek.com/v1"
        case .ollama: return "http://localhost:11434/v1"
        case .lmStudio: return "http://localhost:1234/v1"
        case .custom: return ""
        }
    }

    /// Cheap and good enough for short answers and naming; the service's list of models is in Settings too.
    public var defaultModel: String {
        switch self {
        case .anthropic: return "claude-haiku-5-5"
        case .openAI: return "gpt-5-nano"
        case .gemini: return "gemini-flash-lite-latest"
        case .openRouter: return "openai/gpt-5-nano"
        case .groq: return "llama-3.1-8b-instant"
        case .mistral: return "mistral-small-latest"
        case .deepSeek: return "deepseek-chat"
        case .ollama: return "llama3.2"
        // Whatever is loaded: Settings fills it in from the server's list.
        case .lmStudio, .custom: return ""
        }
    }

    /// Runs on this Mac: no key needed.
    public var isLocal: Bool { self == .ollama || self == .lmStudio }

    /// Where a terminal keeps the key, for a browser started from one when none is entered.
    public var environmentKey: String {
        switch self {
        case .anthropic: return "ANTHROPIC_API_KEY"
        case .openAI, .custom: return "OPENAI_API_KEY"
        case .gemini: return "GEMINI_API_KEY"
        case .openRouter: return "OPENROUTER_API_KEY"
        case .groq: return "GROQ_API_KEY"
        case .mistral: return "MISTRAL_API_KEY"
        case .deepSeek: return "DEEPSEEK_API_KEY"
        case .ollama, .lmStudio: return ""
        }
    }

    /// Where to get a key.
    public var keyPage: String? {
        switch self {
        case .anthropic: return "https://console.anthropic.com/settings/keys"
        case .openAI: return "https://platform.openai.com/api-keys"
        case .gemini: return "https://aistudio.google.com/apikey"
        case .openRouter: return "https://openrouter.ai/keys"
        case .groq: return "https://console.groq.com/keys"
        case .mistral: return "https://console.mistral.ai/api-keys"
        case .deepSeek: return "https://platform.deepseek.com/api_keys"
        case .ollama, .lmStudio, .custom: return nil
        }
    }
}

/// The AI features, each of which can be off, and the service they use. Nothing runs until it's connected.
public struct AISettings: Codable, Equatable {
    public var provider = AIProvider.anthropic
    /// Empty: the provider's own.
    public var baseURL = ""
    public var model = ""
    /// "Ask AI" in the command bar (⌘T).
    public var ask = true
    /// "Rename with AI" in a tab's menu.
    public var rename = true
    /// "Tidy" next to Today's Clear: Today's tabs into folders by topic.
    public var tidy = true

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AISettings()
        provider = (try? c.decodeIfPresent(AIProvider.self, forKey: .provider)) ?? defaults.provider
        baseURL = (try? c.decodeIfPresent(String.self, forKey: .baseURL)) ?? defaults.baseURL
        model = (try? c.decodeIfPresent(String.self, forKey: .model)) ?? defaults.model
        ask = (try? c.decodeIfPresent(Bool.self, forKey: .ask)) ?? defaults.ask
        rename = (try? c.decodeIfPresent(Bool.self, forKey: .rename)) ?? defaults.rename
        tidy = (try? c.decodeIfPresent(Bool.self, forKey: .tidy)) ?? defaults.tidy
    }

    public var resolvedBaseURL: String {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? provider.defaultBaseURL : trimmed
    }

    public var resolvedModel: String {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? provider.defaultModel : trimmed
    }
}

/// What went wrong, in words a person can act on. Background features stay quiet about it; the command bar says it
/// and offers the search instead.
public enum AIError: Error, Equatable {
    case noKey, noModel, badKey, billing, rateLimited, overloaded, badModel, offline, timedOut, refused, unreadable
    case failed(String)

    public var message: String {
        switch self {
        case .noKey: return L("ai.error.noKey")
        case .noModel: return L("ai.error.noModel")
        case .badKey: return L("ai.error.badKey")
        case .billing: return L("ai.error.billing")
        case .rateLimited: return L("ai.error.rateLimited")
        case .overloaded: return L("ai.error.overloaded")
        case .badModel: return L("ai.error.badModel")
        case .offline: return L("ai.error.offline")
        case .timedOut: return L("ai.error.timedOut")
        case .refused: return L("ai.error.refused")
        case .unreadable: return L("ai.error.unreadable")
        case let .failed(detail): return L("ai.error.failed", detail)
        }
    }

    /// Fixed in Settings (the key, the model, the account), not by waiting.
    public var needsSettings: Bool {
        switch self {
        case .noKey, .noModel, .badKey, .billing, .badModel: return true
        default: return false
        }
    }

    public init(_ error: URLError) {
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
            self = .offline
        case .timedOut: self = .timedOut
        default: self = .failed(error.localizedDescription)
        }
    }
}

/// One request: instructions, the conversation so far (questions and answers, oldest first) and the new text, and how
/// long the answer may be (a ceiling with room for the model's own brief thinking; only what's written is paid for).
/// With a `schema`, the answer is a JSON object of that shape.
public struct AIRequest {
    public var system: String
    public var history: [(question: String, answer: String)]
    public var prompt: String
    public var maxTokens: Int
    public var schema: [String: Any]?

    public init(system: String, history: [(question: String, answer: String)] = [], prompt: String, maxTokens: Int,
                schema: [String: Any]? = nil) {
        self.system = system
        self.history = history
        self.prompt = prompt
        self.maxTokens = maxTokens
        self.schema = schema
    }

    var messages: [[String: String]] {
        history.flatMap { [["role": "user", "content": $0.question], ["role": "assistant", "content": $0.answer]] }
            + [["role": "user", "content": prompt]]
    }
}

/// A piece of a streamed answer.
public enum AIStreamEvent: Equatable {
    case text(String)
    case done
    case failed(AIError)
}

/// The two kinds of service's requests and replies, as bytes; the app sends them. Kept here so they can be tested.
public enum AIWire {
    public static let anthropicVersion = "2026-10-21"

    private static func base(_ settings: AISettings) throws -> String {
        var base = settings.resolvedBaseURL
        while base.hasSuffix("/") { base.removeLast() }
        guard !base.isEmpty else { throw AIError.failed(L("ai.error.noAddress")) }
        return base
    }

    private static func headers(_ settings: AISettings, key: String) -> [String: String] {
        switch settings.provider.api {
        case .anthropic: return ["x-api-key": key, "anthropic-version": anthropicVersion]
        case .openAI: return key.isEmpty ? [:] : ["authorization": "Bearer \(key)"]
        }
    }

    public static func urlRequest(_ request: AIRequest, settings: AISettings, key: String, stream: Bool) throws -> URLRequest {
        let model = settings.resolvedModel
        guard !model.isEmpty else { throw AIError.noModel }
        let base = try base(settings)
        var body: [String: Any]
        let path: String
        switch settings.provider.api {
        case .anthropic:
            path = base.hasSuffix("/v1") ? "/messages" : "/v1/messages"
            body = ["model": model, "max_tokens": request.maxTokens, "system": request.system, "messages": request.messages]
            var output: [String: Any] = [:]
            // As little thinking as the model allows: these are small, quick jobs, and every token is paid for.
            if supportsEffort(model) { output["effort"] = "low" }
            if let schema = request.schema { output["format"] = ["type": "json_schema", "schema": schema] }
            if !output.isEmpty { body["output_config"] = output }
        case .openAI:
            path = "/chat/completions"
            var system = request.system
            if let schema = request.schema, let data = try? JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys]),
               let text = String(data: data, encoding: .utf8) {
                // json_object is what every compatible service accepts; the shape goes in the instructions.
                system += "\n\nReply with only a JSON object matching this JSON Schema:\n" + text
            }
            body = ["model": model, "max_tokens": request.maxTokens, "messages": [["role": "system", "content": system]] + request.messages]
            if request.schema != nil { body["response_format"] = ["type": "json_object"] }
        }
        if stream { body["stream"] = true }
        guard let url = URL(string: base + path) else { throw AIError.failed(base) }
        var urlRequest = URLRequest(url: url, timeoutInterval: stream ? 120 : 45)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        headers(settings, key: key).forEach { urlRequest.setValue($0.value, forHTTPHeaderField: $0.key) }
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return urlRequest
    }

    /// The service's list of models, for Settings to offer.
    public static func modelsRequest(settings: AISettings, key: String) throws -> URLRequest {
        let base = try base(settings)
        let path = settings.provider.api == .anthropic ? (base.hasSuffix("/v1") ? "/models?limit=100" : "/v1/models?limit=100") : "/models"
        guard let url = URL(string: base + path) else { throw AIError.failed(base) }
        var request = URLRequest(url: url, timeoutInterval: 20)
        headers(settings, key: key).forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        return request
    }

    /// The models' names in a list reply (`data[].id`, which both kinds use; Gemini's own names lose "models/").
    public static func models(from data: Data) -> [String] {
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        let list = (json["data"] as? [[String: Any]]) ?? (json["models"] as? [[String: Any]]) ?? []
        var seen = Set<String>()
        return list.compactMap { ($0["id"] as? String) ?? ($0["name"] as? String) }
            .map { $0.hasPrefix("models/") ? String($0.dropFirst(7)) : $0 }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .sorted()
    }

    /// Models that take `output_config.effort`; older ones reject it.
    static func supportsEffort(_ model: String) -> Bool {
        ["claude-haiku-5", "claude-sonnet-5", "claude-opus-5", "claude-fable", "claude-mythos", "claude-opus-4-6", "claude-opus-4-7",
         "claude-opus-4-8", "claude-sonnet-4-6"].contains { model.hasPrefix($0) }
    }

    /// The answer's text from a whole (not streamed) reply.
    public static func text(from data: Data, api: AIProvider.API) throws -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AIError.unreadable }
        switch api {
        case .anthropic:
            if json["stop_reason"] as? String == "refusal" { throw AIError.refused }
            let blocks = json["content"] as? [[String: Any]] ?? []
            let text = blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
            guard !text.isEmpty else { throw AIError.unreadable }
            return text
        case .openAI:
            let choice = (json["choices"] as? [[String: Any]])?.first
            guard let text = (choice?["message"] as? [String: Any])?["content"] as? String, !text.isEmpty else { throw AIError.unreadable }
            return text
        }
    }

    /// One `data:` line of a streamed reply (the part after "data: ").
    public static func event(fromLine line: String, api: AIProvider.API) -> AIStreamEvent? {
        if line == "[DONE]" { return .done }
        guard let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return nil }
        switch api {
        case .anthropic:
            switch json["type"] as? String {
            case "content_block_delta":
                let delta = json["delta"] as? [String: Any]
                // Thinking comes as its own deltas; only the answer is shown.
                guard delta?["type"] as? String == "text_delta", let text = delta?["text"] as? String else { return nil }
                return .text(text)
            case "message_delta":
                if (json["delta"] as? [String: Any])?["stop_reason"] as? String == "refusal" { return .failed(.refused) }
                return nil
            case "message_stop": return .done
            case "error":
                let error = json["error"] as? [String: Any]
                return .failed(Self.error(type: error?["type"] as? String, code: nil, message: error?["message"] as? String, status: nil))
            default: return nil
            }
        case .openAI:
            if let error = json["error"] as? [String: Any] {
                return .failed(Self.error(type: error["type"] as? String, code: error["code"] as? String, message: error["message"] as? String, status: nil))
            }
            let choice = (json["choices"] as? [[String: Any]])?.first
            if let text = (choice?["delta"] as? [String: Any])?["content"] as? String, !text.isEmpty { return .text(text) }
            return nil
        }
    }

    /// What an unsuccessful status and its body mean.
    public static func error(status: Int, body: Data) -> AIError {
        let json = (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
        let error = json["error"] as? [String: Any]
        return Self.error(type: error?["type"] as? String, code: error?["code"] as? String, message: error?["message"] as? String ?? (json["error"] as? String),
                          status: status)
    }

    private static func error(type: String?, code: String?, message: String?, status: Int?) -> AIError {
        let text = (message ?? "").lowercased()
        // Anthropic answers a spent balance with a 400, OpenAI with a 429.
        if code == "insufficient_quota" || type == "billing_error" || text.contains("credit balance") || text.contains("quota") { return .billing }
        if type == "authentication_error" || type == "permission_error" || code == "invalid_api_key" { return .badKey }
        if type == "not_found_error" || code == "model_not_found" { return .badModel }
        if type == "rate_limit_error" { return .rateLimited }
        if type == "overloaded_error" || type == "api_error" { return .overloaded }
        switch status {
        case 401, 403: return .badKey
        case 402: return .billing
        case 404: return .badModel
        case 429: return .rateLimited
        case let status? where status >= 500: return .overloaded
        default: return .failed(message ?? status.map { "HTTP \($0)" } ?? "")
        }
    }

    /// The JSON object in an answer, also when a model wrapped it in a code fence or a sentence.
    public static func jsonObject(in text: String) -> [String: Any]? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else { return nil }
        return try? JSONSerialization.jsonObject(with: Data(text[start...end].utf8)) as? [String: Any]
    }
}

// MARK: - the features' prompts

/// "Ask AI" from the command bar: short, direct answers, and follow-up questions on them.
public enum AskAI {
    public static func request(_ question: String, after history: [(question: String, answer: String)] = []) -> AIRequest {
        AIRequest(system: """
            You answer questions typed into a web browser's address bar. Answer directly and briefly: a few sentences or a \
            short list, no preamble. Use the language of the question. Use simple Markdown (bold, lists, inline code) only \
            when it helps. If the question needs current information you may not have, say so in one sentence.
            """, history: history, prompt: question, maxTokens: 4000)
    }
}

/// "Rename with AI" from a tab's menu: a short name of the page's title and host, which are all that's sent.
public enum TabNaming {
    public static func request(for tab: SidebarItem) -> AIRequest {
        AIRequest(system: """
            You name a browser tab for a narrow sidebar. Given the page's site and title, reply with a name of 1 to 4 words, \
            at most 28 characters, that says what the page is: keep the specific subject (the document, product, film, \
            person, question or article), drop the site's name, counters, slogans and separators unless they are the \
            subject. Keep the title's language. Never invent anything that isn't there. Reply with the name only.
            """, prompt: "\(URL(string: tab.url)?.host ?? "")\n\(tab.title.isEmpty ? tab.url : tab.title)", maxTokens: 1024)
    }

    /// The name in the answer: its first line, without quotes or a full stop.
    public static func parse(_ text: String) -> String? {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let name = line.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\"'«»“”.*`")))
        return name.isEmpty ? nil : String(name.prefix(40))
    }
}

/// "Tidy Today": Today's tabs in groups by topic, each a folder to be. The titles and hosts are what's sent.
public enum TidyToday {
    public struct Group: Equatable {
        public let name: String
        public let tabs: [SidebarItem]

        public static func == (a: Group, b: Group) -> Bool { a.name == b.name && a.tabs.map(\.id) == b.tabs.map(\.id) }
    }

    /// Fewer than this, there's nothing to tidy.
    public static let minimum = 4

    public static func request(for tabs: [SidebarItem]) -> AIRequest {
        let lines = tabs.enumerated().map { index, tab in
            "\(index + 1)\t\(URL(string: tab.url)?.host ?? "")\t\(tab.displayTitle.replacingOccurrences(of: "\n", with: " "))"
        }
        return AIRequest(system: """
            You group a person's open browser tabs (number, site, title) by what they are working on, so each group can \
            become a folder. Make 2 to 6 groups of at least 2 tabs each; a tab that fits no group is left out. Name each \
            group in 1 to 3 words, in the language most titles are in, by its topic or task (not "Misc" or "Other").
            """, prompt: lines.joined(separator: "\n"), maxTokens: 1024 + tabs.count * 8, schema: [
            "type": "object", "additionalProperties": false, "required": ["groups"],
            "properties": ["groups": ["type": "array", "items": [
                "type": "object", "additionalProperties": false, "required": ["name", "tabs"],
                "properties": ["name": ["type": "string"], "tabs": ["type": "array", "items": ["type": "integer"]]],
            ]]],
        ])
    }

    /// The groups in the answer: each tab in one group at most, groups of fewer than two left out.
    public static func parse(_ text: String, tabs: [SidebarItem]) -> [Group] {
        let groups = AIWire.jsonObject(in: text)?["groups"] as? [[String: Any]] ?? []
        var used = Set<Int>()
        return groups.compactMap { entry in
            guard let name = (entry["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
            let numbers = (entry["tabs"] as? [Any] ?? []).compactMap { ($0 as? Int) ?? ($0 as? String).flatMap(Int.init) }
            let members = numbers.filter { tabs.indices.contains($0 - 1) && used.insert($0).inserted }.map { tabs[$0 - 1] }
            return members.count >= 2 ? Group(name: String(name.prefix(40)), tabs: members) : nil
        }
    }
}
