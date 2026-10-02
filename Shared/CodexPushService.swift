import Foundation

nonisolated enum CodexPushService {
    static let baseURL = URL(string: "https://codex-buddy-api.snapenda-daniel.workers.dev")!

    static func publish(snapshot: CodexStatusSnapshot, secret: String) async throws -> PublishReceipt {
        let data = try await send(path: "api/push/status", body: snapshot, secret: secret)
        let receipt = try CodexStatusCache.decoder.decode(PublishReceipt.self, from: data)
        guard receipt.providerConfigured else { throw PushError.providerNotConfigured }
        guard receipt.registeredTokens == 0 || receipt.delivered > 0 else {
            throw PushError.deliveryFailed
        }
        return receipt
    }

    private static func send<Body: Encodable>(path: String, body: Body, secret: String) async throws -> Data {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        request.httpBody = try CodexStatusCache.encoder.encode(body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse,
              (200 ..< 300).contains(response.statusCode) else {
            throw PushError.rejected
        }
        return data
    }

    struct PublishReceipt: Decodable, Sendable {
        let delivered: Int
        let failed: Int
        let providerConfigured: Bool
        let registeredTokens: Int
    }

    enum PushError: Error {
        case deliveryFailed
        case providerNotConfigured
        case rejected
    }
}
