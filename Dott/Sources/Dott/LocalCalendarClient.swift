import EventKit
import Foundation

/// Reads events from the macOS Calendar store via EventKit. Work/Google
/// calendars synced into Calendar.app show up here, so no OAuth is needed.
final class LocalCalendarClient {
    private let store = EKEventStore()

    var isAuthorized: Bool {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    @discardableResult
    func requestAccess() async -> Bool {
        if isAuthorized { return true }
        return (try? await store.requestFullAccessToEvents()) ?? false
    }

    func events(from start: Date, to end: Date) async throws -> [CalendarEvent] {
        guard await requestAccess() else { throw CalendarError.accessDenied }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate).compactMap { event in
            guard !event.isAllDay, event.status != .canceled,
                let startDate = event.startDate, let endDate = event.endDate
            else { return nil }
            // Skip meetings the user declined -- they didn't attend them.
            if event.attendees?.contains(where: { $0.isCurrentUser && $0.participantStatus == .declined }) == true {
                return nil
            }
            let title = event.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return CalendarEvent(
                id: event.eventIdentifier ?? UUID().uuidString,
                calendarID: event.calendar?.calendarIdentifier ?? "local",
                summary: title.isEmpty ? "Untitled event" : title,
                start: startDate,
                end: endDate,
                attendees: (event.attendees ?? []).compactMap { attendee in
                    guard let name = attendee.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty
                    else { return nil }
                    return CalendarAttendee(displayName: name)
                })
        }
    }

    enum CalendarError: LocalizedError {
        case accessDenied

        var errorDescription: String? {
            "Calendar access denied. Allow Dott in System Settings > Privacy & Security > Calendars."
        }
    }
}
