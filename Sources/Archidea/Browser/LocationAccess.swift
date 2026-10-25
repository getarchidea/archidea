import AppKit
import CoreLocation

/// macOS's own say on the location. A site the person lets have it only gets it once macOS lets Archidea have it, and
/// macOS asks that once, in its own dialog. The engine didn't ask: a site waited for a position that never came and
/// timed out. So Archidea asks the first time a site is let have the location, and says so when macOS has it off.
final class LocationAccess: NSObject, CLLocationManagerDelegate {
    static let shared = LocationAccess()

    enum State: String { case allowed, undecided, off }

    private let manager = CLLocationManager()
    private var waiting: [(Bool) -> Void] = []

    private override init() {
        super.init()
        manager.delegate = self
    }

    /// Off covers both a no for Archidea and Location Services off for the whole Mac: macOS reports either as denied.
    var state: State {
        switch manager.authorizationStatus {
        case .notDetermined: .undecided
        case .denied, .restricted: .off
        default: .allowed
        }
    }

    /// Whether Archidea may have the location, asking macOS first if it never has.
    func ensure(_ completion: @escaping (Bool) -> Void) {
        Trace.log("location: macOS says \(state.rawValue)")
        switch state {
        case .allowed: completion(true)
        case .off: completion(false)
        case .undecided:
            waiting.append(completion)
            if waiting.count == 1 { manager.requestWhenInUseAuthorization() }
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard state != .undecided, !waiting.isEmpty else { return }
        Trace.log("location: macOS answered \(state.rawValue)")
        let answered = waiting
        waiting = []
        answered.forEach { $0(state == .allowed) }
    }

    /// Where the person turns it back on.
    static func openSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") else { return }
        NSWorkspace.shared.open(url)
    }
}
