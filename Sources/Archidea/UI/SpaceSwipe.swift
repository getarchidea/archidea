import AppKit
import ArchideaCore

/// Two fingers across the sidebar page between spaces, as in Arc: the list follows the fingers (with a rubber band
/// past the first and last space), and on letting go it either carries on to the neighbour — when pulled a quarter
/// of the way or flicked — or springs back. The momentum after the fingers lift is swallowed. The first clear
/// movement decides the gesture: up or down scrolls the list to the end, sideways pages. Docked or slid out over the
/// page, the sidebar is the same.
final class SpaceSwipe {
    private unowned let sidebar: SidebarView
    /// The space a swipe by this offset brings: fingers moving right the previous one, left the next. None past the ends.
    private let neighbour: (CGFloat) -> Space?
    private let hasSeveralSpaces: () -> Bool
    private let arrive: (Space) -> Void

    private var offset: CGFloat = 0
    private var velocity: CGFloat = 0
    private var tracking = false
    /// The gesture went up or down first: it scrolls the list, all the way to the end.
    private var scrolling = false
    private var consumed = false

    init(sidebar: SidebarView, hasSeveralSpaces: @escaping () -> Bool, neighbour: @escaping (CGFloat) -> Space?,
         arrive: @escaping (Space) -> Void) {
        self.sidebar = sidebar
        self.hasSeveralSpaces = hasSeveralSpaces
        self.neighbour = neighbour
        self.arrive = arrive
    }

    /// Whether the scroll event (at `point`, in the sidebar's superview) was the swipe's and goes no further.
    func handle(_ event: NSEvent, at point: NSPoint) -> Bool {
        guard event.hasPreciseScrollingDeltas, hasSeveralSpaces() else { return false }
        if event.momentumPhase != [] { return consumed }
        switch event.phase {
        case .began:
            // Every gesture starts afresh, and is the sidebar's only if it begins there.
            offset = 0
            tracking = false
            scrolling = false
            consumed = false
            guard sidebar.frame.contains(point) else { return false }
            Trace.log("swipe: two fingers down on the sidebar")
            return false
        case .changed:
            guard !scrolling, sidebar.frame.contains(point) || tracking else { return false }
            if !tracking {
                let across = abs(event.scrollingDeltaX), along = abs(event.scrollingDeltaY)
                if along > across, along > 1 {
                    scrolling = true
                    return false
                }
                guard across > along * 1.5, across > 1 else { return false }
                tracking = true
                Trace.log("swipe: sideways, the list follows")
            }
            offset += event.scrollingDeltaX
            velocity = event.scrollingDeltaX
            let width = sidebar.bounds.width
            sidebar.swipeOffset = neighbour(offset) != nil ? max(-width, min(width, offset)) : offset / 3
            return true
        case .ended, .cancelled:
            scrolling = false
            guard tracking else { return false }
            tracking = false
            consumed = true
            let width = sidebar.bounds.width
            let flick = abs(velocity) > 14 && (velocity > 0) == (offset > 0)
            if event.phase == .ended, let next = neighbour(offset), abs(offset) > width * 0.25 || flick {
                Trace.log("swipe: on to the next space (\(Int(abs(offset))) of \(Int(width)) pt\(flick ? ", flicked" : ""))")
                let outward: CGFloat = offset > 0 ? width : -width
                sidebar.settleSwipe(at: outward, duration: 0.16) { [weak self] in
                    guard let self else { return }
                    sidebar.swipeOffset = 0
                    arrive(next)
                }
            } else {
                Trace.log("swipe: back (\(Int(abs(offset))) of \(Int(width)) pt, \(neighbour(offset) == nil ? "no space that way" : "not far enough"))")
                sidebar.settleSwipe(at: 0, duration: 0.28)
            }
            offset = 0
            return true
        default:
            return false
        }
    }
}
