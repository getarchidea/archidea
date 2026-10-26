import XCTest
@testable import ArchideaCore

final class AITests: XCTestCase {
    private func body(_ request: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
    }

    func testAnthropicRequestIsCheapAndAsksForJSON() throws {
        let request = try AIWire.urlRequest(AIRequest(system: "s", prompt: "p", maxTokens: 100, schema: ["type": "object"]),
                                            settings: AISettings(), key: "k", stream: false)
        XCTAssertEqual(request.url?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "k")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2026-10-21")
        let json = try body(request)
        XCTAssertEqual(json["model"] as? String, "claude-haiku-5-5")
        XCTAssertEqual(json["max_tokens"] as? Int, 100)
        XCTAssertNil(json["temperature"], "the 2026-10-21 API version rejects sampling settings")
        let output = try XCTUnwrap(json["output_config"] as? [String: Any])
        XCTAssertEqual(output["effort"] as? String, "low")
        XCTAssertEqual((output["format"] as? [String: Any])?["type"] as? String, "json_schema")
    }

    func testAnOlderModelGetsNoEffort() throws {
        var settings = AISettings()
        settings.model = "claude-haiku-4-5"
        let json = try body(AIWire.urlRequest(AIRequest(system: "s", prompt: "p", maxTokens: 10), settings: settings, key: "k", stream: true))
        XCTAssertNil(json["output_config"])
        XCTAssertEqual(json["stream"] as? Bool, true)
    }

    func testEveryServiceComesFilledIn() throws {
        for provider in AIProvider.allCases where provider != .custom {
            XCTAssertFalse(provider.defaultBaseURL.isEmpty, "\(provider)")
            XCTAssertTrue(provider == .lmStudio || !provider.defaultModel.isEmpty, "\(provider) has a model to start with")
            XCTAssertTrue(provider.isLocal || provider.keyPage != nil, "\(provider) says where to get a key")
        }
        var settings = AISettings()
        settings.provider = .gemini
        let request = try AIWire.urlRequest(AIRequest(system: "s", prompt: "p", maxTokens: 10), settings: settings, key: "k", stream: false)
        XCTAssertEqual(request.url?.absoluteString, "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions")
        XCTAssertEqual(try body(request)["model"] as? String, "gemini-flash-lite-latest")
    }

    func testOpenAICompatibleRequest() throws {
        var settings = AISettings()
        settings.provider = .custom
        XCTAssertThrowsError(try AIWire.urlRequest(AIRequest(system: "s", prompt: "p", maxTokens: 10), settings: settings, key: "k", stream: false)) {
            XCTAssertEqual($0 as? AIError, .noModel)
        }
        settings.model = "some-model"
        settings.baseURL = "http://localhost:11434/v1/"
        let request = try AIWire.urlRequest(AIRequest(system: "s", history: [("q1", "a1")], prompt: "p", maxTokens: 10, schema: ["type": "object"]),
                                            settings: settings, key: "k", stream: false)
        XCTAssertEqual(request.url?.absoluteString, "http://localhost:11434/v1/chat/completions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "authorization"), "Bearer k")
        let json = try body(request)
        XCTAssertEqual((json["response_format"] as? [String: Any])?["type"] as? String, "json_object")
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.map { $0["role"] as? String }, ["system", "user", "assistant", "user"])
        XCTAssertTrue((messages.first?["content"] as? String)?.contains("JSON Schema") == true)
    }

    func testModelLists() throws {
        let openAI = #"{"object":"list","data":[{"id":"b-model"},{"id":"a-model"},{"id":"a-model"}]}"#
        XCTAssertEqual(AIWire.models(from: Data(openAI.utf8)), ["a-model", "b-model"])
        let gemini = #"{"data":[{"id":"models/gemini-flash-lite-latest"}]}"#
        XCTAssertEqual(AIWire.models(from: Data(gemini.utf8)), ["gemini-flash-lite-latest"])
        let request = try AIWire.modelsRequest(settings: AISettings(), key: "k")
        XCTAssertEqual(request.url?.absoluteString, "https://api.anthropic.com/v1/models?limit=100")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "k")
    }

    func testAnswersAreReadPastThinking() throws {
        let reply = #"{"content":[{"type":"thinking","thinking":""},{"type":"text","text":"Hello"}],"stop_reason":"end_turn"}"#
        XCTAssertEqual(try AIWire.text(from: Data(reply.utf8), api: .anthropic), "Hello")
        let refusal = #"{"content":[],"stop_reason":"refusal"}"#
        XCTAssertThrowsError(try AIWire.text(from: Data(refusal.utf8), api: .anthropic)) { XCTAssertEqual($0 as? AIError, .refused) }
        let openAI = #"{"choices":[{"message":{"role":"assistant","content":"Hi"}}]}"#
        XCTAssertEqual(try AIWire.text(from: Data(openAI.utf8), api: .openAI), "Hi")
    }

    func testStreamEvents() {
        XCTAssertEqual(AIWire.event(fromLine: #"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Hi"}}"#, api: .anthropic),
                       .text("Hi"))
        XCTAssertNil(AIWire.event(fromLine: #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"x"}}"#, api: .anthropic))
        XCTAssertEqual(AIWire.event(fromLine: #"{"type":"message_stop"}"#, api: .anthropic), .done)
        XCTAssertEqual(AIWire.event(fromLine: #"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#, api: .anthropic),
                       .failed(.overloaded))
        XCTAssertEqual(AIWire.event(fromLine: #"{"choices":[{"delta":{"content":"Yo"}}]}"#, api: .openAI), .text("Yo"))
        XCTAssertEqual(AIWire.event(fromLine: "[DONE]", api: .openAI), .done)
    }

    func testErrorsSayWhatToDo() {
        func error(_ status: Int, _ body: String) -> AIError { AIWire.error(status: status, body: Data(body.utf8)) }
        XCTAssertEqual(error(401, #"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#), .badKey)
        XCTAssertEqual(error(400, #"{"type":"error","error":{"type":"invalid_request_error","message":"Your credit balance is too low"}}"#), .billing)
        XCTAssertEqual(error(429, #"{"error":{"message":"You exceeded your current quota","code":"insufficient_quota"}}"#), .billing)
        XCTAssertEqual(error(429, #"{"error":{"type":"rate_limit_error","message":"slow down"}}"#), .rateLimited)
        XCTAssertEqual(error(529, ""), .overloaded)
        XCTAssertEqual(error(404, #"{"error":{"type":"not_found_error","message":"model: x"}}"#), .badModel)
        XCTAssertTrue(AIError.billing.needsSettings)
        XCTAssertFalse(AIError.rateLimited.needsSettings)
    }

    func testRenamingATab() {
        let tab = SidebarItem(tab: "https://www.kinopoisk.example/film/1", title: "Some Film (2026) — смотреть онлайн в хорошем качестве — Кинопоиск")
        let request = TabNaming.request(for: tab)
        XCTAssertEqual(request.prompt, "www.kinopoisk.example\n" + tab.title)
        XCTAssertEqual(TabNaming.parse("\"Some Film\".\nmore"), "Some Film")
        XCTAssertNil(TabNaming.parse("  \n"))
    }

    func testTidyGroupsKeepEachTabOnceAndDropLoneOnes() {
        let tabs = (1...6).map { SidebarItem(tab: "https://site\($0).example", title: "Page \($0)") }
        let answer = #"""
        Here you go: {"groups":[{"name":"Work","tabs":[1,2,3]},{"name":"Again","tabs":[3,4]},{"name":"Fun","tabs":[5,6,9]}]}
        """#
        let groups = TidyToday.parse(answer, tabs: tabs)
        XCTAssertEqual(groups.map(\.name), ["Work", "Fun"])
        XCTAssertEqual(groups[0].tabs.map(\.url), tabs[0...2].map(\.url))
        XCTAssertEqual(groups[1].tabs.count, 2)
    }

    func testSettingsReadFromOlderFiles() throws {
        let settings = try JSONDecoder().decode(BrowserSettings.self, from: Data(#"{"searchEngine":"google"}"#.utf8))
        XCTAssertEqual(settings.ai, AISettings())
        XCTAssertEqual(settings.ai.resolvedModel, "claude-haiku-5-5")
    }
}
