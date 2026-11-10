import Foundation

nonisolated enum RelayConfiguration {
    // Replace with your HTTPS deployment, or set a relay in the Mac pairing window.
    static let defaultURL = URL(string: "https://danieldev.top")!
}

nonisolated enum RelayError: LocalizedError {
    case invalidEndpoint
    case invalidKey
    case invalidMessage
    case queueFull

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: return "请输入中转服务器的 HTTPS 地址，例如 https://relay.example.com，不要附带路径、查询或账户信息。"
        case .invalidKey: return "配对密钥无效，请重新扫描 Mac 的配对二维码。"
        case .invalidMessage: return "消息验证失败，请重新配对。"
        case .queueFull: return "上一张照片仍在发送，请稍后重试。"
        }
    }
}

nonisolated enum RelayEndpoint {
    static func validated(_ url: URL) throws -> URL {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == "https",
              let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil,
              parts.percentEncodedPath.isEmpty || parts.percentEncodedPath == "/",
              parts.port == nil || (1...65535).contains(parts.port!)
        else { throw RelayError.invalidEndpoint }
        parts.scheme = "https"
        parts.path = ""
        guard let normalized = parts.url else { throw RelayError.invalidEndpoint }
        return normalized
    }
}

nonisolated enum RelayInvitation {
    static func request(code: String, pairing: PairingInfo) throws -> URLRequest {
        let code = code.trimmingCharacters(in: .whitespacesAndNewlines)
        let alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
        guard code.count == 35, code.hasPrefix("SI-"),
              code.dropFirst(3).allSatisfy({ alphabet.contains($0) })
        else { throw RelayInvitationError.invalidCode }
        let endpoint = try RelayEndpoint.validated(pairing.relayURL)
        let cipher = try RelayCipher(pairing: pairing)
        let url = endpoint.appendingPathComponent("v1/snapinsert/invitations/redeem")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("Bearer \(cipher.relayToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(Redemption(code: code, room: cipher.room))
        return request
    }

    static func validateResponse(data: Data, response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw RelayInvitationError.unavailable }
        guard http.statusCode == 200 else {
            switch http.statusCode {
            case 400, 403: throw RelayInvitationError.invalidCode
            case 409: throw RelayInvitationError.alreadyUsed
            case 429: throw RelayInvitationError.rateLimited
            default: throw RelayInvitationError.unavailable
            }
        }
        guard let result = try? JSONDecoder().decode(Authorization.self, from: data),
              result.status == "authorized" else { throw RelayInvitationError.unavailable }
    }

    private struct Redemption: Encodable { let code: String; let room: String }
    private struct Authorization: Decodable { let status: String }
}

nonisolated enum RelayInvitationError: LocalizedError {
    case invalidCode, alreadyUsed, rateLimited, unavailable

    var errorDescription: String? {
        switch self {
        case .invalidCode: return "邀请码无效或已撤销，请向维护者获取有效邀请码。"
        case .alreadyUsed: return "群组配对名额已满，或此配对已有其他授权。请联系维护者确认。"
        case .rateLimited: return "尝试次数过多，请稍后再试。"
        case .unavailable: return "暂时无法激活中转，请检查网络并稍后重试。"
        }
    }
}
