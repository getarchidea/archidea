import CryptoKit
import Foundation

/// Release versions as tags and latest.json write them ("0.1.5", "v0.2"): compared number by number.
enum ReleaseVersion {
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let parts = { (text: String) in text.split(whereSeparator: { !$0.isNumber }).map { Int($0) ?? 0 } }
        let a = parts(candidate), b = parts(current)
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0, y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
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
