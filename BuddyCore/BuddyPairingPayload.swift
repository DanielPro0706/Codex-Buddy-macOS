import Foundation

/// Application-only pairing. Keep this out of widget/watch targets, which do not
/// include the SnapInsert transport and its device keychain model.
nonisolated struct BuddyPairingPayload: Equatable {
    let limits: MacConnection?
    let snapInsert: PairingInfo?

    var isUnified: Bool { limits != nil && snapInsert != nil }

    var legacyNotice: String? {
        guard !isUnified else { return nil }
        let feature = limits != nil ? "Limits" : "SnapInsert"
        let missing = limits != nil ? "SnapInsert" : "Limits"
        return "这是旧版 \(feature) 配对信息，只连接该功能。请扫描 Mac 上新版 Codex Buddy 的统一二维码，补齐 \(missing) 配对。"
    }

    init(urlString: String) throws {
        guard !urlString.isEmpty, urlString.utf8.count <= 8192,
              !Self.containsControls(urlString), !urlString.contains(where: \.isWhitespace),
              !urlString.contains("\\"), Self.hasValidPercentEncoding(urlString),
              let parts = URLComponents(string: urlString),
              parts.host == "pair", parts.user == nil, parts.password == nil,
              parts.port == nil, parts.path.isEmpty, parts.fragment == nil else {
            throw ValidationError.invalidPayload
        }
        if parts.scheme == "snapinsert" {
            let info = try PairingInfo(urlString: urlString)
            guard !Self.containsControls(info.name) else { throw ValidationError.invalidPayload }
            limits = nil
            snapInsert = info
            return
        }
        guard parts.scheme == "codexbuddynew", let items = parts.queryItems,
              Set(items.map(\.name)).count == items.count,
              Set(items.map(\.name)) == Set(["url", "token"])
                || Set(items.map(\.name)) == Set(["url", "token", "snapinsert"]),
              items.allSatisfy({ $0.value != nil }) else {
            throw ValidationError.invalidPayload
        }
        let values = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value!) })
        guard let address = values["url"], let token = values["token"] else {
            throw ValidationError.invalidPayload
        }
        limits = try Self.validatedLimits(address: address, token: token)
        if let nested = values["snapinsert"] {
            let info = try PairingInfo(urlString: nested)
            guard !Self.containsControls(info.name) else { throw ValidationError.invalidPayload }
            snapInsert = info
        } else {
            snapInsert = nil
        }
    }

    static func unifiedURL(limits: MacConnection, snapInsert: PairingInfo) throws -> URL {
        let validated = try validatedLimits(address: limits.baseURL.absoluteString, token: limits.accessToken)
        let snap = try PairingInfo(urlString: snapInsert.urlString)
        guard var parts = validated.pairingURL.flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false) }) else {
            throw ValidationError.invalidPayload
        }
        parts.queryItems?.append(URLQueryItem(name: "snapinsert", value: snap.urlString))
        guard let url = parts.url else { throw ValidationError.invalidPayload }
        _ = try Self(urlString: url.absoluteString)
        return url
    }

    static func limitsOnlyURL(address: String, token: String) throws -> URL {
        let connection = try validatedLimits(address: address.trimmingCharacters(in: .whitespacesAndNewlines), token: token)
        guard let url = connection.pairingURL else { throw ValidationError.invalidPayload }
        return url
    }

    /// Persist SnapInsert first: a rejected Mac switch or keychain failure must
    /// never leave Limits pointing to a different Mac from the retained queue.
    @discardableResult
    func apply(pairSnapInsert: (PairingInfo) -> Bool, pairLimits: (MacConnection) -> Void) -> Bool {
        if let snapInsert, !pairSnapInsert(snapInsert) { return false }
        if let limits { pairLimits(limits) }
        return true
    }

    static func canReplaceSnapInsert(current: PairingInfo?, incoming: PairingInfo, hasPendingPhotos: Bool) -> Bool {
        guard hasPendingPhotos else { return true }
        guard let current else { return false }
        return current.id == incoming.id && current.key == incoming.key && current.relayURL == incoming.relayURL
    }

    private static func validatedLimits(address: String, token: String) throws -> MacConnection {
        guard address.utf8.count <= 2048, !containsControls(address),
              !address.contains(where: \.isWhitespace), !address.contains("\\"),
              let parts = URLComponents(string: address),
              ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
              let host = parts.host, !host.isEmpty, !containsControls(host),
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.port.map({ (1...65535).contains($0) }) ?? true,
              parts.percentEncodedPath.isEmpty || parts.percentEncodedPath == "/",
              let url = parts.url,
              !token.isEmpty, token.utf8.count <= 512,
              !containsControls(token), !token.contains(where: \.isWhitespace) else {
            throw ValidationError.invalidLimits
        }
        return MacConnection(baseURL: url, accessToken: token)
    }

    private static func containsControls(_ value: String) -> Bool {
        value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    private static func hasValidPercentEncoding(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        func isHex(_ byte: UInt8) -> Bool {
            (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
        }
        var index = 0
        while index < bytes.count {
            if bytes[index] == 37 {
                guard index + 2 < bytes.count, isHex(bytes[index + 1]), isHex(bytes[index + 2]) else { return false }
                index += 3
            } else { index += 1 }
        }
        return true
    }

    enum ValidationError: LocalizedError {
        case invalidPayload, invalidLimits
        var errorDescription: String? {
            switch self {
            case .invalidPayload: "无法识别配对信息。请重新扫描 Mac 上 Codex Buddy 的统一二维码。"
            case .invalidLimits: "Limits 配对信息无效。请使用不含账号、查询参数或路径的 HTTP(S) Mac 地址及有效访问令牌。"
            }
        }
    }
}
