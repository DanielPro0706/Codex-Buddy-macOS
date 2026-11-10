import Foundation

enum CloudSpaceConfiguration {
    static let defaultsKey = "cloudSpace.gatewayURL"
    static let projectURL = URL(string: "https://github.com/DanielPro0706/codex-icloud-workspace")!
    static let setupURL = URL(string: "https://github.com/DanielPro0706/codex-icloud-workspace/blob/main/docs/01-server-setup.md")!

    enum AddressError: LocalizedError {
        case invalidAddress
        case unsupportedScheme
        case embeddedCredentials

        var errorDescription: String? {
            switch self {
            case .invalidAddress:
                "请输入完整的 gateway 地址，例如 https://gateway.example.ts.net/。"
            case .unsupportedScheme:
                "gateway 地址必须使用 HTTPS 或 HTTP。"
            case .embeddedCredentials:
                "请填写不含账号、密码、查询参数或片段的地址，并在 gateway 页面完成认证。"
            }
        }
    }

    static func gatewayURL(from address: String) throws -> URL {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.contains(where: { $0.isWhitespace || $0.isNewline || $0.asciiValue.map({ $0 < 32 || $0 == 127 }) == true }),
              !trimmed.contains("\\"),
              var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased() else {
            throw AddressError.invalidAddress
        }
        guard scheme == "https" || scheme == "http" else {
            throw AddressError.unsupportedScheme
        }
        guard components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else {
            throw AddressError.embeddedCredentials
        }
        guard let host = components.host, !host.isEmpty,
              components.port.map({ (1...65535).contains($0) }) ?? true else {
            throw AddressError.invalidAddress
        }
        components.scheme = scheme
        components.host = host.lowercased()
        if components.path.isEmpty {
            components.path = "/"
        }
        guard let url = components.url else { throw AddressError.invalidAddress }
        return url
    }
}
