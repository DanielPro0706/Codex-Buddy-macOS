import Foundation
import Security

nonisolated enum PairingError: LocalizedError {
    case invalidLink
    case invalidKey
    case oldVersion
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidLink: return "配对二维码无效，请重新扫描 Mac 上的二维码。"
        case .invalidKey: return "配对密钥无效。"
        case .oldVersion: return "旧版局域网配对已停止使用，请重新扫描 Mac 上的新版配对二维码。"
        case .keychain(let status):
            return "无法访问配对钥匙串（\(status)）。"
        }
    }
}

nonisolated struct PairingInfo: Codable, Equatable {
    let id: UUID
    let name: String
    let key: Data
    let relayURL: URL

    init(id: UUID, name: String, key: Data, relayURL: URL = RelayConfiguration.defaultURL) {
        self.id = id
        self.name = name
        self.key = key
        self.relayURL = relayURL
    }

    var urlString: String {
        var components = URLComponents()
        components.scheme = "snapinsert"
        components.host = "pair"
        let secret = key.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        components.queryItems = [
            URLQueryItem(name: "v", value: "2"),
            URLQueryItem(name: "id", value: id.uuidString),
            URLQueryItem(name: "name", value: name),
            URLQueryItem(name: "key", value: secret),
            URLQueryItem(name: "relay", value: relayURL.absoluteString)
        ]
        return components.string ?? ""
    }

    init(urlString: String) throws {
        guard urlString.utf8.count <= 4096,
              let parts = URLComponents(string: urlString),
              parts.scheme == "snapinsert", parts.host == "pair",
              parts.user == nil, parts.password == nil, parts.port == nil,
              parts.path.isEmpty, parts.fragment == nil,
              let items = parts.queryItems
        else { throw PairingError.invalidLink }
        if items.contains(where: { $0.name == "v" && $0.value == "1" }) { throw PairingError.oldVersion }
        guard items.count == 5,
              Set(items.map(\.name)) == Set(["v", "id", "name", "key", "relay"])
        else { throw PairingError.invalidLink }
        let values = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        guard values["v"] == "2", let rawID = values["id"], let id = UUID(uuidString: rawID),
              let name = values["name"], !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name.utf8.count <= 255,
              let rawKey = values["key"], rawKey.count == 43,
              rawKey.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
        else { throw PairingError.invalidLink }
        let encoded = rawKey.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/") + "="
        guard let key = Data(base64Encoded: encoded), key.count == 32 else { throw PairingError.invalidKey }
        guard let rawRelay = values["relay"], let relay = URL(string: rawRelay) else { throw RelayError.invalidEndpoint }
        self.init(id: id, name: name, key: key, relayURL: try RelayEndpoint.validated(relay))
    }

    static func create(name: String, relayURL: URL = RelayConfiguration.defaultURL) throws -> Self {
        let relay = try RelayEndpoint.validated(relayURL)
        var bytes = [UInt8](repeating: 0, count: 32)
        let result = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard result == errSecSuccess else { throw PairingError.keychain(result) }
        let safeName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return Self(id: UUID(), name: String((safeName.isEmpty ? "Mac" : safeName).prefix(63)), key: Data(bytes), relayURL: relay)
    }
}

nonisolated enum PairingStore {
    private static let service = "com.snapinsert.pairing.v1"

    static func load(account: String) throws -> PairingInfo? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw PairingError.keychain(status) }
        let value = try JSONDecoder().decode(PairingInfo.self, from: data)
        // Apply the same validation used for untrusted QR input to stored data.
        return try PairingInfo(urlString: value.urlString)
    }

    static func save(_ value: PairingInfo, account: String) throws {
        _ = try PairingInfo(urlString: value.urlString)
        let data = try JSONEncoder().encode(value)
        let query = baseQuery(account: account)
        let attributes: [String: Any] = [kSecValueData as String: data]
        let update = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw PairingError.keychain(update) }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw PairingError.keychain(status) }
    }

    static func remove(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw PairingError.keychain(status) }
    }

    private static func baseQuery(account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: false]
    }
}
