import Foundation

nonisolated enum CodexStatusClient {
    static func fetch(connection: MacConnection) async throws -> CodexStatusSnapshot {
        let endpoint = connection.baseURL.appending(path: "v1/status")
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("Bearer \(connection.accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw ConnectionError.invalidResponse
        }
        guard response.statusCode != 401 else { throw ConnectionError.unauthorized }
        guard (200 ..< 300).contains(response.statusCode) else {
            throw ConnectionError.server(response.statusCode)
        }

        do {
            return try CodexStatusCache.decoder
                .decode(CodexStatusSnapshot.self, from: data)
                .receivedFromMac()
        } catch {
            throw ConnectionError.invalidResponse
        }
    }

    static func refreshedSnapshot() async -> CodexStatusSnapshot? {
        let cachedSnapshot = CodexStatusCache.loadSnapshot()
        if let connection = CodexStatusCache.loadConnection(),
           let snapshot = try? await fetch(connection: connection) {
            CodexStatusCache.save(snapshot: snapshot)
            return snapshot
        }

        if let cloudState = try? await CodexCloudSync.fetch() {
            if let secret = cloudState.pushSecret { CodexStatusCache.savePushSecret(secret) }
            guard let cloudSnapshot = cloudState.snapshot else { return cachedSnapshot }
            let newest = [cachedSnapshot, cloudSnapshot]
                .compactMap { $0 }
                .max { $0.capturedAt < $1.capturedAt }
            if let newest { CodexStatusCache.save(snapshot: newest) }
            return newest
        }

        return cachedSnapshot
    }

    static func publishToCloud(_ snapshot: CodexStatusSnapshot) async {
        let secret = CodexStatusCache.loadOrCreatePushSecret()
        do {
            _ = try await CodexCloudSync.publish(snapshot: snapshot, pushSecret: secret)
            try await CodexPushService.publish(snapshot: snapshot, secret: secret)
        } catch {
            // Local and LAN synchronization remain available while iCloud or APNs is unavailable.
        }
    }

    static func refreshFromCloud() async -> CodexStatusSnapshot? {
        do {
            let state = try await CodexCloudSync.fetch()
            if let secret = state.pushSecret { CodexStatusCache.savePushSecret(secret) }
            if let snapshot = state.snapshot { CodexStatusCache.save(snapshot: snapshot) }
            return state.snapshot
        } catch {
            return CodexStatusCache.loadSnapshot()
        }
    }

    private static func legacyRefresh(connection: MacConnection) async -> CodexStatusSnapshot? {
        do {
            let snapshot = try await fetch(connection: connection)
            CodexStatusCache.save(snapshot: snapshot)
            return snapshot
        } catch {
            return nil
        }
    }

    enum ConnectionError: LocalizedError {
        case invalidResponse
        case unauthorized
        case server(Int)

        var errorDescription: String? {
            switch self {
            case .invalidResponse: "Mac 返回了无法识别的数据"
            case .unauthorized: "访问令牌不正确"
            case let .server(code): "Mac 同步服务暂时不可用（\(code)）"
            }
        }
    }
}
