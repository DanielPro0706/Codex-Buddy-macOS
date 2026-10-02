import Foundation

nonisolated enum CodexStatusClient {
    static func publishToCloud(_ snapshot: CodexStatusSnapshot) async -> CodexCloudSync.OperationStatus {
        let secret = CodexStatusCache.loadOrCreatePushSecret()
        do {
            _ = try await CodexCloudSync.publish(snapshot: snapshot, pushSecret: secret)
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
}
