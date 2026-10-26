import Foundation

/// What the address bar makes of typed text: an address as it is, a bare host with a scheme, anything else a search.
public enum URLInput {
    public static var engine = SearchEngine.google
    public static var searchTemplate: String { engine.template }

    public static func resolve(_ raw: String) -> String {
        let input = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if input.isEmpty { return "about:blank" }
        let lower = input.lowercased()
        for scheme in ["http://", "https://", "file://", "about:", "chrome:", "chrome-extension:", "data:", "view-source:"] where lower.hasPrefix(scheme) {
            return input
        }
        if !input.contains(" ") {
            let host = lower.split(separator: "/").first.map(String.init) ?? lower
            let bare = host.split(separator: ":").first.map(String.init) ?? host
            if bare == "localhost" || bare.hasSuffix(".localhost") || isIPv4(bare) { return "http://\(input)" }
            if let tld = bare.split(separator: ".").last, bare.contains("."), tld.count >= 2, tld.allSatisfy(\.isLetter) {
                return "https://\(input)"
            }
        }
        return search(input)
    }

    /// The search engine's page for `text`, whatever it looks like (an address too).
    public static func search(_ text: String) -> String {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let query = input.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? input
        return searchTemplate.replacingOccurrences(of: "%@", with: query)
    }

    /// Selected text as a menu names it: on one line, its runs of spaces as one, cut short after `limit` characters.
    public static func selectionLabel(_ text: String, limit: Int = 32) -> String {
        let line = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return line.count > limit ? String(line.prefix(limit - 1)) + "…" : line
    }

    public static func isSearch(_ input: String) -> Bool {
        let prefix = searchTemplate.components(separatedBy: "%@")[0]
        return resolve(input).hasPrefix(prefix)
    }

    private static func isIPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".")
        return parts.count == 4 && parts.allSatisfy { Int($0).map { (0...255).contains($0) } ?? false }
    }
}

extension CharacterSet {
    public static let urlQueryValueAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "&+=?#")
        return set
    }()
}
