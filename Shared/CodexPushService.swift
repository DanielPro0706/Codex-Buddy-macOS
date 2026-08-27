import Foundation

nonisolated enum CodexPushService {
    static let baseURL = URL(string: "https://codex-buddy-api.snapenda-daniel.workers.dev")!

    enum TokenKind: String, Codable, Sendable {
        case app
        case widget
        case liveActivity
        case pushToStart
    }

    static func register(token: Data, kind: TokenKind, secret: String) async throws {
        let body = TokenRegistration(
            token: token.hexadecimalString,
            kind: kind,
            activityID: nil,
            environment: pushEnvironment
        )
        try await send(path: "api/push/register", body: body, secret: secret)
    }

    static func registerLiveActivity(token: Data, activityID: String, secret: String) async throws {
        let body = TokenRegistration(
            token: token.hexadecimalString,
            kind: .liveActivity,
            activityID: activityID,
            environment: pushEnvironment
        )
        try await send(path: "api/push/register", body: body, secret: secret)
    }

    static func publish(snapshot: CodexStatusSnapshot, secret: String) async throws {
        try await send(path: "api/push/status", body: snapshot, secret: secret)
    }

    private static func send<Body: Encodable>(path: String, body: Body, secret: String) async throws {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        request.httpBody = try CodexStatusCache.encoder.encode(body)
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse,
              (200 ..< 300).contains(response.statusCode) else {
            throw PushError.rejected
        }
    }

    private static var pushEnvironment: String {
        #if DEBUG
        "sandbox"
        #else
        "production"
        #endif
    }

    private struct TokenRegistration: Codable {
        let token: String
        let kind: TokenKind
        let activityID: String?
        let environment: String
    }

    enum PushError: Error { case rejected }
}

private extension Data {
    nonisolated var hexadecimalString: String { map { String(format: "%02x", $0) }.joined() }
}
