import Foundation

nonisolated enum WireError: LocalizedError {
    case invalidLength
    case invalidMessage
    case notReady
    case timeout

    var errorDescription: String? {
        switch self {
        case .invalidLength: return "图片或消息超过允许大小。"
        case .invalidMessage: return "收到的消息格式无效。"
        case .notReady: return "Mac 尚未连接，请稍后重试。"
        case .timeout: return "连接超时，请检查两台设备的网络。"
        }
    }
}

nonisolated struct WireMessage: Codable, Equatable {
    enum Kind: String, Codable { case photo, receipt, photoRequest, photoChallenge }
    let kind: Kind
    let id: UUID
    var jpeg: Data?
    var status: String?
    var detail: String?
    var attempt: UUID?
    var challenge: UUID?

    static func photo(id: UUID, jpeg: Data, attempt: UUID? = nil, challenge: UUID? = nil) -> Self {
        Self(kind: .photo, id: id, jpeg: jpeg, attempt: attempt, challenge: challenge)
    }

    static func receipt(id: UUID, status: String, detail: String, attempt: UUID? = nil) -> Self {
        Self(kind: .receipt, id: id, status: status, detail: detail, attempt: attempt)
    }

    static func photoRequest(id: UUID, attempt: UUID) -> Self {
        Self(kind: .photoRequest, id: id, attempt: attempt)
    }

    static func photoChallenge(id: UUID, attempt: UUID, challenge: UUID) -> Self {
        Self(kind: .photoChallenge, id: id, attempt: attempt, challenge: challenge)
    }

    func validate() throws {
        switch kind {
        case .photo:
            guard let jpeg, !jpeg.isEmpty, jpeg.count <= WireFrame.maximumImageLength,
                  status == nil, detail == nil, (attempt == nil) == (challenge == nil)
            else { throw WireError.invalidMessage }
        case .receipt:
            guard jpeg == nil, challenge == nil, let status, !status.isEmpty, status.utf8.count <= 64,
                  let detail, detail.utf8.count <= 4096 else { throw WireError.invalidMessage }
        case .photoRequest, .photoChallenge:
            guard jpeg == nil, status == nil, detail == nil, attempt != nil,
                  (kind == .photoChallenge) == (challenge != nil)
            else { throw WireError.invalidMessage }
        }
    }
}

/// One pending authorization per relay channel. A proof is spent before image decoding.
nonisolated struct PhotoAuthorization {
    private var pending: WireMessage?
    private var deadline: ContinuousClock.Instant?

    mutating func issue(for request: WireMessage, now: ContinuousClock.Instant = .now) -> WireMessage? {
        guard request.kind == .photoRequest, let attempt = request.attempt else { return nil }
        let response = WireMessage.photoChallenge(id: request.id, attempt: attempt, challenge: UUID())
        pending = response
        deadline = now.advanced(by: .seconds(30))
        return response
    }

    mutating func consume(_ photo: WireMessage, now: ContinuousClock.Instant = .now) -> Bool {
        guard photo.kind == .photo, let pending, let deadline, now < deadline,
              pending.id == photo.id, pending.attempt == photo.attempt, pending.challenge == photo.challenge
        else { return false }
        self = Self()
        return true
    }
}

nonisolated enum WireFrame {
    static let maximumImageLength = 12 * 1024 * 1024
    static let maximumFrameLength = 18 * 1024 * 1024

    static func encode(_ message: WireMessage) throws -> Data {
        try message.validate()
        let payload = try JSONEncoder().encode(message)
        guard payload.count <= maximumFrameLength else { throw WireError.invalidLength }
        var length = UInt32(payload.count).bigEndian
        var frame = withUnsafeBytes(of: &length) { Data($0) }
        frame.append(payload)
        return frame
    }

    static func payloadLength(header: Data) throws -> Int {
        guard header.count == 4 else { throw WireError.invalidLength }
        // Reduce avoids assuming alignment of the received byte buffer.
        let length = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard length > 0, length <= UInt32(maximumFrameLength) else { throw WireError.invalidLength }
        return Int(length)
    }

    static func decode(payload: Data) throws -> WireMessage {
        guard !payload.isEmpty, payload.count <= maximumFrameLength else { throw WireError.invalidLength }
        let message = try JSONDecoder().decode(WireMessage.self, from: payload)
        try message.validate()
        return message
    }
}
