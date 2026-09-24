import Foundation

final class GoogleCalendarClient {
    private let configuration: GoogleOAuthConfiguration
    private let tokenStore: KeychainTokenStore
    private let session: URLSession
    private let decoder: JSONDecoder

    init(configuration: GoogleOAuthConfiguration, tokenStore: KeychainTokenStore = KeychainTokenStore()) {
        self.configuration = configuration
        self.tokenStore = tokenStore
        self.session = URLSession(configuration: .ephemeral)
        self.decoder = JSONDecoder()
    }

    func events(from start: Date, to end: Date) async throws -> [CalendarEvent] {
        guard let token = tokenStore.load() else { throw CalendarError.notConnected }
        var components = URLComponents(string: "https://www.googleapis.com/calendar/v3/calendars/primary/events")!
        components.queryItems = [
            URLQueryItem(name: "timeMin", value: ISO8601DateFormatter().string(from: start)),
            URLQueryItem(name: "timeMax", value: ISO8601DateFormatter().string(from: end)),
            URLQueryItem(name: "singleEvents", value: "true"),
            URLQueryItem(name: "orderBy", value: "startTime"),
            URLQueryItem(name: "maxResults", value: "2500"),
        ]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CalendarError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw CalendarError.httpStatus(http.statusCode)
        }
        let page = try decoder.decode(EventPage.self, from: data)
        return page.items.compactMap { $0.local() }
    }

    struct EventPage: Decodable {
        let items: [GoogleEvent]
    }

    struct GoogleEvent: Decodable {
        let id: String
        let summary: String?
        let status: String?
        let start: EventTime
        let end: EventTime
        let attendees: [GoogleAttendee]?

        func local(calendarID: String = "primary") -> CalendarEvent? {
            guard status != "cancelled", let startDate = start.parsedDate, let endDate = end.parsedDate else { return nil }
            return CalendarEvent(
                id: id,
                calendarID: calendarID,
                summary: summary ?? "Untitled event",
                start: startDate,
                end: endDate,
                attendees: (attendees ?? []).compactMap { attendee in
                    guard let name = attendee.displayName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
                    return CalendarAttendee(displayName: name)
                })
        }
    }

    struct EventTime: Decodable {
        let dateTime: String?
        let dateValue: String?

        enum CodingKeys: String, CodingKey {
            case dateTime
            case dateValue = "date"
        }

        var parsedDate: Date? {
            if let dateTime { return ISO8601DateFormatter().date(from: dateTime) }
            if let dateValue { return ISO8601DateFormatter().date(from: dateValue + "T00:00:00Z") }
            return nil
        }
    }

    struct GoogleAttendee: Decodable {
        let displayName: String?
    }

    enum CalendarError: LocalizedError {
        case notConnected
        case invalidResponse
        case httpStatus(Int)

        var errorDescription: String? {
            switch self {
            case .notConnected: return "Google Calendar is not connected."
            case .invalidResponse: return "Google Calendar returned an invalid response."
            case .httpStatus(let status): return "Google Calendar request failed (HTTP \(status))."
            }
        }
    }
}
