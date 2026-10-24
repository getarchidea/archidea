import CryptoKit
import XCTest
@testable import ArchideaCore

final class ReleaseVersionTests: XCTestCase {
    func testVersionsCompareNumberByNumber() {
        XCTAssertTrue(ReleaseVersion.isNewer("0.1.10", than: "0.1.9"))
        XCTAssertTrue(ReleaseVersion.isNewer("v0.2", than: "0.1.5"))
        XCTAssertTrue(ReleaseVersion.isNewer("1.0.0", than: "0.99.99"))
        XCTAssertFalse(ReleaseVersion.isNewer("0.1.5", than: "0.1.5"))
        XCTAssertFalse(ReleaseVersion.isNewer("0.1", than: "0.1.0"))
        XCTAssertFalse(ReleaseVersion.isNewer("0.1.4", than: "0.1.5"))
    }
}

/// Signatures made here the way `minisign -S -l` makes them, checked the way the updater checks a download.
final class MinisignTests: XCTestCase {
    private let key = Curve25519.Signing.PrivateKey()
    private let keyID = Data([1, 2, 3, 4, 5, 6, 7, 8])
    private var file: URL!

    override func setUpWithError() throws {
        file = FileManager.default.temporaryDirectory.appendingPathComponent("archidea-\(UUID().uuidString).zip")
        try Data("the app".utf8).write(to: file)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: file)
    }

    private var publicKey: String {
        (Data("Ed".utf8) + keyID + key.publicKey.rawRepresentation).base64EncodedString()
    }

    private func signature(of contents: Data, comment: String) throws -> String {
        let signature = try key.signature(for: contents)
        let global = try key.signature(for: signature + Data(comment.utf8))
        return """
        untrusted comment: signature from minisign secret key
        \((Data("Ed".utf8) + keyID + signature).base64EncodedString())
        trusted comment: \(comment)
        \(global.base64EncodedString())
        """
    }

    func testAGoodSignatureVerifies() throws {
        let text = try signature(of: Data("the app".utf8), comment: "archidea v1.0 file.zip")
        XCTAssertTrue(Minisign.verify(signature: text, file: file, publicKey: publicKey, comment: "archidea v1.0 file.zip"))
    }

    func testAChangedFileDoesNot() throws {
        let text = try signature(of: Data("another app".utf8), comment: "archidea v1.0 file.zip")
        XCTAssertFalse(Minisign.verify(signature: text, file: file, publicKey: publicKey, comment: "archidea v1.0 file.zip"))
    }

    func testAnOlderReleasesSignatureDoesNot() throws {
        let text = try signature(of: Data("the app".utf8), comment: "archidea v0.9 file.zip")
        XCTAssertFalse(Minisign.verify(signature: text, file: file, publicKey: publicKey, comment: "archidea v1.0 file.zip"))
    }

    func testAnotherKeyDoesNot() throws {
        let text = try signature(of: Data("the app".utf8), comment: "c")
        let other = (Data("Ed".utf8) + keyID + Curve25519.Signing.PrivateKey().publicKey.rawRepresentation).base64EncodedString()
        XCTAssertFalse(Minisign.verify(signature: text, file: file, publicKey: other, comment: "c"))
    }
}
