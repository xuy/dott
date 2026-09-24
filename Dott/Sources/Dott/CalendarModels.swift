import Foundation

struct GoogleOAuthConfiguration: Codable {
    struct Installed: Codable {
        let clientID: String
        let clientSecret: String
        let authURI: String
        let tokenURI: String
        let redirectURIs: [String]

        enum CodingKeys: String, CodingKey {
            case clientID = "client_id"
            case clientSecret = "client_secret"
            case authURI = "auth_uri"
            case tokenURI = "token_uri"
            case redirectURIs = "redirect_uris"
        }
    }

    let installed: Installed
}

struct GoogleToken: Codable {
    let accessToken: String
    let refreshToken: String?
    let expiresAt: Date

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresAt = "expires_at"
    }
}

struct CalendarAttendee: Codable, Equatable {
    let displayName: String
}

struct CalendarEvent: Equatable {
    let id: String
    let calendarID: String
    let summary: String
    let start: Date
    let end: Date
    let attendees: [CalendarAttendee]
}

enum CalendarMatch: Equatable {
    case matched(CalendarEvent, confidence: String)
    case ambiguous
    case noMatch
}

struct CalendarMatcher {
    static func match(
        events: [CalendarEvent], recordingStart: Date, recordingEnd: Date,
        zoomTitle: String?
    ) -> CalendarMatch {
        let candidates = events.filter {
            $0.end > recordingStart.addingTimeInterval(-15 * 60)
                && $0.start < recordingEnd.addingTimeInterval(15 * 60)
        }
        guard !candidates.isEmpty else { return .noMatch }

        let ranked = candidates.map { event in
            let overlapStart = max(event.start, recordingStart)
            let overlapEnd = min(event.end, recordingEnd)
            let overlap = max(0, overlapEnd.timeIntervalSince(overlapStart))
            let proximity = abs(event.start.timeIntervalSince(recordingStart))
            let titleBonus: Double = {
                guard let zoomTitle, !zoomTitle.isEmpty else { return 0 }
                return event.summary.localizedCaseInsensitiveContains(zoomTitle) ? 300 : 0
            }()
            return (event, score: overlap * 10 + titleBonus - proximity)
        }.sorted { $0.score > $1.score }

        guard let best = ranked.first else { return .noMatch }
        if ranked.count > 1, best.score - ranked[1].score < 60 {
            return .ambiguous
        }
        return .matched(best.0, confidence: best.score > 0 ? "high" : "low")
    }
}
