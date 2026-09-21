import CoreGraphics
import Foundation

struct ZoomCallInfo: Equatable {
    let rawWindowTitle: String
    let meetingTitle: String?

    init(rawWindowTitle: String) {
        self.rawWindowTitle = rawWindowTitle
        self.meetingTitle = Self.meetingTitle(from: rawWindowTitle)
    }

    static func meetingTitle(from windowTitle: String) -> String? {
        let suffix = "Zoom Meeting"
        guard windowTitle.hasSuffix(suffix) else { return nil }
        let prefix = String(windowTitle.dropLast(suffix.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-–—:"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return prefix.isEmpty ? nil : prefix
    }

    var folderSlug: String? {
        Self.folderSlug(for: meetingTitle)
    }

    static func folderSlug(for meetingTitle: String?) -> String? {
        guard let meetingTitle else { return nil }
        let normalized = meetingTitle.precomposedStringWithCanonicalMapping
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let safe = normalized.unicodeScalars.map { scalar -> Character in
            if CharacterSet.controlCharacters.contains(scalar)
                || scalar == "/" || scalar == "\\" || scalar == ":"
            {
                return "-"
            }
            return Character(String(scalar))
        }
        let slug = String(safe)
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "--+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        guard !slug.isEmpty else { return nil }
        return String(slug.prefix(100))
    }
}

/// Detects whether you're actually in an active Zoom call, by polling the
/// window list for a window whose name ends in "Zoom Meeting" (Zoom titles
/// it "<Host>'s Zoom Meeting" on join, then plain "Zoom Meeting" once the
/// main call view is up) with onscreen == true.
final class ZoomWatcher {
    /// Fires on state transitions only (not on every poll).
    var onCallStateChanged: ((ZoomCallInfo?) -> Void)?

    private var timer: Timer?
    private var isInCall = false
    private var consecutiveOffPolls = 0
    private let offDebounceThreshold = 2

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    private func poll() {
        let callInfo = Self.activeCallInfo()

        if let callInfo {
            consecutiveOffPolls = 0
            if !isInCall {
                isInCall = true
                onCallStateChanged?(callInfo)
            }
        } else if isInCall {
            consecutiveOffPolls += 1
            if consecutiveOffPolls >= offDebounceThreshold {
                isInCall = false
                consecutiveOffPolls = 0
                onCallStateChanged?(nil)
            }
        }
    }

    private static func activeCallInfo() -> ZoomCallInfo? {
        guard let list = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID)
            as? [[String: AnyObject]] else { return nil }

        for window in list {
            guard let owner = window[kCGWindowOwnerName as String] as? String,
                owner.lowercased().contains("zoom") else { continue }
            let name = window[kCGWindowName as String] as? String ?? ""
            let onscreen = window[kCGWindowIsOnscreen as String] as? Bool ?? false
            if onscreen && name.hasSuffix("Zoom Meeting") {
                return ZoomCallInfo(rawWindowTitle: name)
            }
        }
        return nil
    }
}
