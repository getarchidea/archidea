import AppKit

/// Links other apps hand to Archidea as the default browser: a sign-in link from a desktop app, a link clicked in Mail.
/// macOS sends them as a "get URL" Apple Event. The engine registers its own handler for that event during launch and
/// swallows the link, so ours goes in before the engine starts (to catch the link that launched the app) and again
/// once it's up; links that arrive before the browser window exists wait here.
enum IncomingLinks {
    private static var pending: [URL] = []
    private static let receiver = Receiver()

    /// Where links go once the browser is ready.
    static var handler: ((URL) -> Void)? {
        didSet {
            guard let handler else { return }
            let waiting = pending
            pending.removeAll()
            waiting.forEach(handler)
        }
    }

    static func install() {
        NSAppleEventManager.shared().setEventHandler(receiver, andSelector: #selector(Receiver.getURL(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    static func receive(_ url: URL) {
        Trace.log("link from another app: \(url.scheme ?? "?")://\(url.host ?? "")")
        if let handler { handler(url) } else { pending.append(url) }
    }

    private final class Receiver: NSObject {
        @objc func getURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
            guard let text = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
                  let url = URL(string: text) else { return }
            IncomingLinks.receive(url)
        }
    }
}
