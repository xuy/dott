import AppKit
import Foundation
import Network

@MainActor
final class GoogleOAuth: ObservableObject {
    @Published private(set) var isConnected: Bool
    @Published private(set) var isConnecting = false
    @Published var errorMessage: String?

    private let configuration: GoogleOAuthConfiguration
    private let tokenStore: KeychainTokenStore
    private var listener: NWListener?
    static let changedNotification = Notification.Name("DottCalendarOAuthChanged")
    private var redirectURI: String?

    init(configuration: GoogleOAuthConfiguration, tokenStore: KeychainTokenStore = KeychainTokenStore()) {
        self.configuration = configuration
        self.tokenStore = tokenStore
        isConnected = tokenStore.load() != nil
    }

    func connect() {
        guard !isConnecting else { return }
        isConnecting = true
        errorMessage = nil
        NotificationCenter.default.post(name: Self.changedNotification, object: nil)

        do {
            let listener = try NWListener(using: .tcp, on: .any)
            self.listener = listener
            listener.stateUpdateHandler = { [weak self] state in
                guard case .ready = state, let port = listener.port else { return }
                Task { @MainActor in
                    self?.openAuthorization(port: port.rawValue)
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                connection.start(queue: .global(qos: .userInitiated))
                self?.receiveCallback(from: connection)
            }
            listener.start(queue: .global(qos: .userInitiated))
        } catch {
            isConnecting = false
            errorMessage = "Could not start Google sign-in: \(error.localizedDescription)"
        }
    }

    func disconnect() {
        listener?.cancel()
        listener = nil
        tokenStore.delete()
        isConnected = false
    }

    private func openAuthorization(port: UInt16) {
        let state = UUID().uuidString
        redirectURI = "http://localhost:\(port)"
        var components = URLComponents(string: configuration.installed.authURI)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: configuration.installed.clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: "https://www.googleapis.com/auth/calendar.readonly"),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
            URLQueryItem(name: "state", value: state),
        ]
        guard let url = components.url else {
            finishWithError("Could not construct Google sign-in URL.")
            return
        }
        UserDefaults.standard.set(state, forKey: "googleOAuthState")
        NSWorkspace.shared.open(url)
    }

    private nonisolated func receiveCallback(from connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, _, error in
            guard let data, error == nil, let request = String(data: data, encoding: .utf8) else {
                Task { @MainActor in self?.finishWithError("Google sign-in callback failed.") }
                return
            }
            let firstLine = request.components(separatedBy: "\r\n").first ?? ""
            let path = firstLine.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            guard let components = URLComponents(string: "http://localhost\(path)"),
                let query = components.queryItems,
                let code = query.first(where: { $0.name == "code" })?.value,
                let returnedState = query.first(where: { $0.name == "state" })?.value,
                returnedState == UserDefaults.standard.string(forKey: "googleOAuthState")
            else {
                Task { @MainActor in self?.finishWithError("Google sign-in was denied or returned an invalid state.") }
                return
            }
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nConnection: close\r\n\r\n<h1>Dott is connected to Google Calendar.</h1><p>You can close this window.</p>"
            connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in connection.cancel() })
            Task { @MainActor in self?.exchange(code: code) }
        }
    }

    private func exchange(code: String) {
        var request = URLRequest(url: URL(string: configuration.installed.tokenURI)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = [
            "code": code,
            "client_id": configuration.installed.clientID,
            "client_secret": configuration.installed.clientSecret,
            "redirect_uri": redirectURI ?? "http://localhost",
            "grant_type": "authorization_code",
        ].map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }.joined(separator: "&")
        request.httpBody = body.data(using: .utf8)
        Task {
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    throw OAuthError.exchangeFailed
                }
                let payload = try JSONDecoder().decode(TokenResponse.self, from: data)
                guard let refreshToken = payload.refreshToken else { throw OAuthError.noRefreshToken }
                let token = GoogleToken(
                    accessToken: payload.accessToken,
                    refreshToken: refreshToken,
                    expiresAt: Date().addingTimeInterval(TimeInterval(payload.expiresIn))
                )
                try tokenStore.save(token)
                await MainActor.run { self.finishSuccess() }
            } catch {
                await MainActor.run { self.finishWithError(error.localizedDescription) }
            }
        }
    }

    private func finishSuccess() {
        NotificationCenter.default.post(name: Self.changedNotification, object: nil)
        listener?.cancel()
        listener = nil
        UserDefaults.standard.removeObject(forKey: "googleOAuthState")
        isConnecting = false
        isConnected = true
    }

    private func finishWithError(_ message: String) {
        NotificationCenter.default.post(name: Self.changedNotification, object: nil)
        listener?.cancel()
        listener = nil
        isConnecting = false
        errorMessage = message
    }

    private struct TokenResponse: Decodable {
        let accessToken: String
        let refreshToken: String?
        let expiresIn: Int

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
        }
    }

    private enum OAuthError: LocalizedError {
        case exchangeFailed
        case noRefreshToken
        var errorDescription: String? {
            switch self {
            case .exchangeFailed: return "Google OAuth token exchange failed."
            case .noRefreshToken: return "Google did not return a refresh token."
            }
        }
    }
}
