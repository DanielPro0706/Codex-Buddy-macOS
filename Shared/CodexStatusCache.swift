import Foundation

nonisolated enum CodexStatusCache {
    static let appGroupIdentifier = "group.com.danieldev.CodexBuddyNew"

    private static let snapshotKey = "codex.status.snapshot.v1"
    private static let connectionKey = "codex.status.connection.v1"
    private static let pushSecretKey = "codex.push.secret.v1"

    private static var defaults: UserDefaults {
        UserDefaults(suiteName: appGroupIdentifier) ?? .standard
    }

    static func loadSnapshot() -> CodexStatusSnapshot? {
        guard let data = defaults.data(forKey: snapshotKey) else { return nil }
        return try? decoder.decode(CodexStatusSnapshot.self, from: data)
    }

    static func save(snapshot: CodexStatusSnapshot) {
        guard let data = try? encoder.encode(snapshot) else { return }
        defaults.set(data, forKey: snapshotKey)
    }

    static func loadConnection() -> MacConnection? {
        guard let data = defaults.data(forKey: connectionKey) else { return nil }
        return try? decoder.decode(MacConnection.self, from: data)
    }

    static func save(connection: MacConnection) {
        guard let data = try? encoder.encode(connection) else { return }
        defaults.set(data, forKey: connectionKey)
    }

    static func clearConnection() {
        defaults.removeObject(forKey: connectionKey)
    }

    static func clearAll() {
        defaults.removeObject(forKey: snapshotKey)
        defaults.removeObject(forKey: connectionKey)
        defaults.removeObject(forKey: pushSecretKey)
    }

    static func loadPushSecret() -> String? {
        defaults.string(forKey: pushSecretKey)
    }

    @discardableResult
    static func loadOrCreatePushSecret() -> String {
        if let existing = loadPushSecret(), !existing.isEmpty { return existing }
        let bytes = (0 ..< 32).map { _ in UInt8.random(in: .min ... .max) }
        let secret = Data(bytes).base64EncodedString()
        defaults.set(secret, forKey: pushSecretKey)
        return secret
    }

    static func savePushSecret(_ secret: String) {
        defaults.set(secret, forKey: pushSecretKey)
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
