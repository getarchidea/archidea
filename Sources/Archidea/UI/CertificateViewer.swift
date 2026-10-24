import AppKit
import SecurityInterface

/// Shows a site's certificate chain in macOS's own certificate viewer, the one Safari uses.
/// The engine reports the certificate's summary but not its bytes, so the chain comes from a short TLS handshake
/// with the same host; the request is cancelled as soon as the server's trust arrives.
final class CertificateViewer: NSObject, URLSessionDelegate {
    private static var running: [CertificateViewer] = []
    private let window: NSWindow
    private var session: URLSession?

    private init(window: NSWindow) {
        self.window = window
    }

    static func show(for url: URL, in window: NSWindow) {
        guard url.scheme == "https", let host = url.host else { return }
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.port = url.port
        guard let target = components.url else { return }
        let viewer = CertificateViewer(window: window)
        running.append(viewer)
        let session = URLSession(configuration: .ephemeral, delegate: viewer, delegateQueue: .main)
        viewer.session = session
        var request = URLRequest(url: target)
        request.httpMethod = "HEAD"
        session.dataTask(with: request) { _, _, _ in viewer.finish() }.resume()
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            return completionHandler(.performDefaultHandling, nil)
        }
        completionHandler(.cancelAuthenticationChallenge, nil)
        let chain = (SecTrustCopyCertificateChain(trust) as? [SecCertificate]) ?? []
        guard !chain.isEmpty else { return finish() }
        SFCertificatePanel.shared().beginSheet(for: window, modalDelegate: nil, didEnd: nil, contextInfo: nil,
                                               certificates: chain, showGroup: true)
        finish()
    }

    private func finish() {
        session?.invalidateAndCancel()
        session = nil
        Self.running.removeAll { $0 === self }
    }
}
