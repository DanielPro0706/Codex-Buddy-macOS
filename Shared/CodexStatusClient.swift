import Foundation

nonisolated enum CodexStatusClient {
    enum RefreshSource: Sendable {
        case mac
        case cloud
        case cache
    }

    struct RefreshResult: Sendable {
        let snapshot: CodexStatusSnapshot?
        let source: RefreshSource
        let cloudStatus: CodexCloudSync.OperationStatus
    }

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

    static func refreshLatest() async -> RefreshResult {
        let cachedSnapshot = CodexStatusCache.loadSnapshot()
        guard !Task.isCancelled else {
            return RefreshResult(snapshot: cachedSnapshot, source: .cache, cloudStatus: .cancelled)
        }
        if let connection = CodexStatusCache.loadConnection() {
            do {
                let snapshot = try await fetch(connection: connection)
                try Task.checkCancellation()
                CodexStatusCache.save(snapshot: snapshot)
                return RefreshResult(snapshot: snapshot, source: .mac, cloudStatus: .notChecked)
            } catch {
                if Task.isCancelled || CodexCloudSync.isCancellation(error) {
                    return RefreshResult(snapshot: cachedSnapshot, source: .cache, cloudStatus: .cancelled)
                }
            }
        }

        return await refreshFromCloudResult(cachedSnapshot: cachedSnapshot)
    }

    static func refreshedSnapshot() async -> CodexStatusSnapshot? {
        await refreshLatest().snapshot
    }

    static func publishToCloud(_ snapshot: CodexStatusSnapshot) async -> CodexCloudSync.OperationStatus {
        guard !Task.isCancelled else { return .cancelled }
        let secret = CodexStatusCache.loadOrCreatePushSecret()
        do {
            _ = try await CodexCloudSync.publish(snapshot: snapshot, pushSecret: secret)
            try Task.checkCancellation()
            do {
                _ = try await CodexPushService.publish(snapshot: snapshot, secret: secret)
            } catch {
                // APNs wake-up is optional and must not turn a successful iCloud save into a failure.
            }
            return .synced(.now)
        } catch {
            return CodexCloudSync.operationStatus(for: error)
        }
    }

    static func refreshFromCloud() async -> CodexStatusSnapshot? {
        await refreshFromCloudResult().snapshot
    }

    static func refreshFromCloudResult() async -> RefreshResult {
        await refreshFromCloudResult(cachedSnapshot: CodexStatusCache.loadSnapshot())
    }

    private static func refreshFromCloudResult(
        cachedSnapshot: CodexStatusSnapshot?
    ) async -> RefreshResult {
        do {
            try Task.checkCancellation()
            let state = try await CodexCloudSync.fetch()
            try Task.checkCancellation()
            if let secret = state.pushSecret { CodexStatusCache.savePushSecret(secret) }
            guard let cloudSnapshot = state.snapshot else {
                return RefreshResult(
                    snapshot: cachedSnapshot,
                    source: .cache,
                    cloudStatus: .connectedWithoutData
                )
            }

            let newestSnapshot: CodexStatusSnapshot
            let source: RefreshSource
            if let cachedSnapshot {
                if cloudSnapshot.capturedAt >= cachedSnapshot.capturedAt {
                    newestSnapshot = cloudSnapshot
                    source = .cloud
                } else {
                    newestSnapshot = cachedSnapshot
                    source = .cache
                }
            } else {
                newestSnapshot = cloudSnapshot
                source = .cloud
            }
            CodexStatusCache.save(snapshot: newestSnapshot)
            return RefreshResult(snapshot: newestSnapshot, source: source, cloudStatus: .synced(.now))
        } catch {
            return RefreshResult(
                snapshot: cachedSnapshot,
                source: .cache,
                cloudStatus: CodexCloudSync.operationStatus(for: error)
            )
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
