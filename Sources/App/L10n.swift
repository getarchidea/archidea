import Foundation

/// The interface language: an explicit choice in Settings, or the system's first preferred language we ship.
enum AppLanguage: String, CaseIterable {
    case system, en, ru

    static let defaultsKey = "DriftLanguage"

    static var setting: AppLanguage {
        get {
            if let forced = ProcessInfo.processInfo.environment["DRIFT_LANGUAGE"], let language = AppLanguage(rawValue: forced) { return language }
            return AppLanguage(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .system
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey) }
    }

    /// The language code actually used, with `system` resolved.
    var resolved: String {
        guard self == .system else { return rawValue }
        let shipped = ["en", "ru"]
        for preferred in Locale.preferredLanguages {
            if let code = shipped.first(where: { preferred.hasPrefix($0) }) { return code }
        }
        return "en"
    }
}

/// All interface text goes through `L(_:)`. Strings live in Resources/<code>.lproj/Localizable.strings,
/// keyed by dotted names; English is the fallback for anything a translation lacks, and
/// scripts/check-strings.sh fails the build when a key used in code is missing from any table.
enum L10n {
    private(set) static var code = "en"
    private static var table: [String: String] = [:]
    private static var fallback: [String: String] = [:]

    /// Called once at launch, before any interface exists; changing the language takes a restart.
    static func configure(_ language: AppLanguage = .setting) {
        code = language.resolved
        fallback = load("en")
        table = code == "en" ? fallback : load(code)
    }

    private static func load(_ code: String) -> [String: String] {
        guard let url = Bundle.main.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: code),
              let dictionary = NSDictionary(contentsOf: url) as? [String: String] else { return [:] }
        return dictionary
    }

    static func string(_ key: String) -> String {
        table[key] ?? fallback[key] ?? key
    }
}

func L(_ key: String) -> String {
    L10n.string(key)
}

func L(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: L10n.string(key), locale: Locale(identifier: L10n.code), arguments: arguments)
}
