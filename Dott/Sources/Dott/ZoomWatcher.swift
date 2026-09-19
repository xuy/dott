import CoreGraphics
import Foundation

/// Detects whether you're actually in an active Zoom call, by polling the
/// window list for a window whose name ends in "Zoom Meeting" (Zoom titles
/// it "<Host>'s Zoom Meeting" on join, then plain "Zoom Meeting" once the
/// main call view is up) with onscreen == true. Confirmed empirically:
/// "Zoom Workplace" (the idle/lobby window) stays onscreen=true always, so
/// it's not a usable signal on its own -- the "Zoom Meeting"-suffixed window
/// only exists while a call is actually live.
final class ZoomWatcher {
    /// Fires on state transitions only (not on every poll).
    var onCallStateChanged: ((Bool) -> Void)?

    private var timer: Timer?
    private var isInCall = false
    private var consecutiveOffPolls = 0
    // Debounce only the OFF transition: cutting a live recording a few
    // seconds late is harmless, cutting it a few seconds early loses audio.
    private let offDebounceThreshold = 2

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    private func poll() {
        let inCallNow = Self.isZoomCallActive()

        if inCallNow {
            consecutiveOffPolls = 0
            if !isInCall {
                isInCall = true
                onCallStateChanged?(true)
            }
        } else if isInCall {
            consecutiveOffPolls += 1
            if consecutiveOffPolls >= offDebounceThreshold {
                isInCall = false
                consecutiveOffPolls = 0
                onCallStateChanged?(false)
            }
        }
    }

    private static func isZoomCallActive() -> Bool {
        guard
            let list = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID)
                as? [[String: AnyObject]]
        else { return false }

        for w in list {
            guard let owner = w[kCGWindowOwnerName as String] as? String,
                owner.lowercased().contains("zoom")
            else { continue }
            let name = w[kCGWindowName as String] as? String ?? ""
            let onscreen = w[kCGWindowIsOnscreen as String] as? Bool ?? false
            if onscreen && name.hasSuffix("Zoom Meeting") {
                return true
            }
        }
        return false
    }
}
