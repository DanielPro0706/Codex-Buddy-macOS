import CryptoKit
import Foundation

/// Server authentication and message encryption use separate derived material.
/// The relay sees the room/token and ciphertext, never the pairing key or JPEG.
nonisolated struct RelayCipher {
    let relayToken: String
    let room: String
    private let key: SymmetricKey

    init(pairing: PairingInfo) throws {
        guard pairing.key.count == 32 else { throw RelayError.invalidKey }
        let tokenMaterial = Data("snapinsert-relay-auth-v2".utf8) + pairing.key
        relayToken = Self.hex(SHA256.hash(data: tokenMaterial))
        room = Self.hex(SHA256.hash(data: Data(relayToken.utf8)))
        key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: pairing.key),
            salt: Data(pairing.id.uuidString.lowercased().utf8),
            info: Data("snapinsert-e2e-v2".utf8), outputByteCount: 32
        )
    }

    func seal(_ message: WireMessage, sender: RelayChannel.Role) throws -> Data {
        let payload = try WireFrame.encode(message).dropFirst(4)
        guard let combined = try AES.GCM.seal(payload, using: key, authenticating: aad(sender: sender)).combined
        else { throw RelayError.invalidMessage }
        return combined
    }

    func open(_ data: Data, sender: RelayChannel.Role) throws -> WireMessage {
        guard data.count >= 28, data.count <= WireFrame.maximumFrameLength + 28 else { throw WireError.invalidLength }
        do {
            let box = try AES.GCM.SealedBox(combined: data)
            let payload = try AES.GCM.open(box, using: key, authenticating: aad(sender: sender))
            return try WireFrame.decode(payload: payload)
        } catch { throw RelayError.invalidMessage }
    }

    private func aad(sender: RelayChannel.Role) -> Data {
        Data("snapinsert-v2|\(room)|\(sender.rawValue)".utf8)
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// Keeps a sealed photo request off the wire until its own transfer slot is granted.
nonisolated struct RelayTransferSlot {
    private struct Transfer {
        let id: UUID
        let photoID: UUID
        let attempt: UUID
        var encryptedRequest: Data?
    }

    private var transfer: Transfer?
    var currentID: UUID? { transfer?.id }

    mutating func begin(_ message: WireMessage, encryptedRequest: Data) throws -> UUID {
        guard transfer == nil else { throw RelayError.queueFull }
        guard message.kind == .photoRequest, let attempt = message.attempt else { throw WireError.invalidMessage }
        let id = UUID()
        transfer = Transfer(id: id, photoID: message.id, attempt: attempt, encryptedRequest: encryptedRequest)
        return id
    }

    mutating func grant(_ id: UUID) -> Data? {
        guard transfer?.id == id, let request = transfer?.encryptedRequest else { return nil }
        transfer?.encryptedRequest = nil
        return request
    }

    func allowsPhoto(_ message: WireMessage) -> Bool {
        guard let transfer else { return false }
        return message.kind == .photo && transfer.encryptedRequest == nil
            && message.id == transfer.photoID && message.attempt == transfer.attempt
    }

    mutating func complete(_ receipt: WireMessage) -> UUID? {
        guard receipt.kind == .receipt, let transfer,
              receipt.id == transfer.photoID, receipt.attempt == transfer.attempt else { return nil }
        self.transfer = nil
        return transfer.id
    }

    mutating func cancel() -> UUID? {
        defer { transfer = nil }
        return transfer?.id
    }
}

@MainActor
final class RelayChannel {
    nonisolated enum Role: String, Codable, Sendable {
        case phone, mac
        var peer: Role { self == .phone ? .mac : .phone }
    }

    var onMessage: ((WireMessage) -> Void)?
    var onReady: (() -> Void)?
    var onClose: ((String) -> Void)?
    var onPeerUnavailable: (() -> Void)?
    var onReplaced: (() -> Void)?
    var onAuthorizationRequired: ((String) -> Void)?
    var onTransferQueued: (() -> Void)?
    var onTransferStarted: (() -> Void)?
    var onTransferUnavailable: ((String) -> Void)?

    private let pairing: PairingInfo
    private let role: Role
    private var cipher: RelayCipher?
    private var session: URLSession?
    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var sendTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private var pingDeadline: Task<Void, Never>?
    private var handshakeDeadline: Task<Void, Never>?
    private var pendingPing: UUID?
    private struct Outgoing {
        let message: URLSessionWebSocketTask.Message
        let byteCount: Int
        let transferID: UUID?
    }
    private var outgoing: [Outgoing] = []
    private var transferSlot = RelayTransferSlot()
    private var supportsTransferControl = false
    private var queuedBytes = 0
    private var started = false
    private var closed = false
    private var peerReady = false

    init(pairing: PairingInfo, role: Role) {
        self.pairing = pairing
        self.role = role
    }

    func start() {
        guard !started, !closed else { return }
        started = true
        do {
            let endpoint = try RelayEndpoint.validated(pairing.relayURL)
            let cipher = try RelayCipher(pairing: pairing)
            self.cipher = cipher
            var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
            components.scheme = "wss"
            components.path = "/v1/rooms/\(cipher.room)/socket/\(role.rawValue)"
            var request = URLRequest(url: components.url!)
            request.setValue("Bearer \(cipher.relayToken)", forHTTPHeaderField: "Authorization")
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 24 * 60 * 60
            let session = URLSession(configuration: configuration)
            self.session = session
            let socket = session.webSocketTask(with: request)
            socket.maximumMessageSize = WireFrame.maximumFrameLength + 28
            self.socket = socket
            socket.resume()
            receiveTask = Task { [weak self] in await self?.receiveLoop() }
            handshakeDeadline = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: 15_000_000_000) } catch { return }
                self?.close(reason: "连接中转服务器超时，请检查网络及服务器地址。")
            }
            pingTask = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(nanoseconds: 20_000_000_000) } catch { return }
                    guard let self, !self.closed else { return }
                    self.ping()
                }
            }
        } catch { close(reason: error.localizedDescription) }
    }

    func send(_ message: WireMessage) throws {
        guard !closed, peerReady, socket != nil, let cipher else { throw WireError.notReady }
        if role == .phone, supportsTransferControl, message.kind == .photo,
           !transferSlot.allowsPhoto(message) { throw WireError.notReady }
        let data = try cipher.seal(message, sender: role)
        if role == .phone, supportsTransferControl, message.kind == .photoRequest {
            let id = try transferSlot.begin(message, encryptedRequest: data)
            do { try enqueueControl(action: "begin", id: id) }
            catch { _ = transferSlot.cancel(); throw error }
            onTransferQueued?()
            return
        }
        try enqueue(.data(data), byteCount: data.count, transferID: transferSlot.currentID)
        if role == .phone, message.kind == .photoRequest { onTransferStarted?() }
    }

    /// Cancelling a queued or uncertain attempt never recalls bytes already sent to the Mac.
    func cancelTransfer() {
        guard let id = transferSlot.cancel() else { return }
        removeOutgoing(for: id)
        guard !closed, socket != nil else { return }
        do { try enqueueControl(action: "cancel", id: id) }
        catch { close(reason: "无法取消中转等待，连接已关闭。") }
    }

    func cancel() { close(reason: "连接已断开。") }

    private func enqueue(_ message: URLSessionWebSocketTask.Message, byteCount: Int, transferID: UUID? = nil) throws {
        guard outgoing.count < 4, queuedBytes + byteCount <= WireFrame.maximumFrameLength + 28
        else { throw RelayError.queueFull }
        outgoing.append(Outgoing(message: message, byteCount: byteCount, transferID: transferID))
        queuedBytes += byteCount
        if sendTask == nil {
            sendTask = Task { [weak self] in await self?.drainOutgoing() }
        }
    }

    private func enqueueControl(action: String, id: UUID) throws {
        let data = try JSONEncoder().encode(TransferCommand(type: "transfer", action: action, id: id.uuidString.lowercased()))
        guard let text = String(data: data, encoding: .utf8) else { throw RelayError.invalidMessage }
        try enqueue(.string(text), byteCount: data.count, transferID: action == "begin" ? id : nil)
    }

    private func removeOutgoing(for id: UUID) {
        outgoing.removeAll { $0.transferID == id }
        queuedBytes = outgoing.reduce(0) { $0 + $1.byteCount }
    }

    private func receiveControl(_ text: String) throws {
        guard text.utf8.count <= 1024 else { throw RelayError.invalidMessage }
        let message = try JSONDecoder().decode(ServerControl.self, from: Data(text.utf8))
        switch message.type {
        case "presence":
            guard let peer = message.peer else { throw RelayError.invalidMessage }
            supportsTransferControl = supportsTransferControl || message.transferControl == true
            handshakeDeadline?.cancel()
            if peer {
                if !peerReady { peerReady = true; onReady?() }
            } else {
                peerReady = false
                _ = transferSlot.cancel()
                outgoing.removeAll()
                queuedBytes = 0
                onPeerUnavailable?()
            }
        case "transfer":
            guard role == .phone, supportsTransferControl, let id = message.id, let state = message.state,
                  ["queued", "granted", "cancelled", "expired"].contains(state)
            else { throw RelayError.invalidMessage }
            guard transferSlot.currentID == id else { return }
            switch state {
            case "queued": break // The deadline began with the original request, not repeated status messages.
            case "granted":
                guard let data = transferSlot.grant(id) else { return }
                try enqueue(.data(data), byteCount: data.count, transferID: id)
                onTransferStarted?()
            default:
                _ = transferSlot.cancel()
                removeOutgoing(for: id)
                onTransferUnavailable?(state == "expired"
                    ? "中转传输名额等待超时，照片已保留，请重试。"
                    : "中转传输已取消，照片已保留，请重试。")
            }
        default: throw RelayError.invalidMessage
        }
    }

    private func receiveLoop() async {
        guard let socket else { return }
        while !closed, !Task.isCancelled {
            do {
                let message = try await socket.receive()
                switch message {
                case .data(let bytes):
                    guard let cipher else { throw RelayError.invalidMessage }
                    let decoded = try cipher.open(bytes, sender: role.peer)
                    // A relay cannot turn a phone photo into a Mac acknowledgement or vice versa.
                    switch (role, decoded.kind) {
                    case (.mac, .photo), (.mac, .photoRequest), (.phone, .receipt), (.phone, .photoChallenge):
                        break
                    default: throw RelayError.invalidMessage
                    }
                    var releaseFailed = false
                    if role == .phone, let id = transferSlot.complete(decoded) {
                        removeOutgoing(for: id)
                        do { try enqueueControl(action: "end", id: id) }
                        catch { releaseFailed = true }
                    }
                    // Preserve a genuine receipt even if the release control cannot be queued.
                    onMessage?(decoded)
                    if releaseFailed { close(reason: "照片回执已收到，正在重新连接中转。") }
                case .string(let text):
                    try receiveControl(text)
                @unknown default: throw RelayError.invalidMessage
                }
            } catch {
                if !closed {
                    if socket.closeCode.rawValue == 4005 {
                        close(reason: "本月额度已用完，可在设置中验证邀请码或开通 Buddy Pro。", authorizationRequired: true)
                    } else if socket.closeCode.rawValue == 4004 {
                        close(reason: "此邀请码的流量额度已用完，请联系维护者调整额度。", authorizationRequired: true)
                    } else if socket.closeCode.rawValue == 4003 || (socket.response as? HTTPURLResponse)?.statusCode == 403 {
                        close(reason: "中转授权不可用，请检查邀请码或联系维护者确认剩余额度。", authorizationRequired: true)
                    } else if socket.closeCode.rawValue == 4001 {
                        close(reason: "连接已被另一台设备替换，请点“重新连接”后继续。", replaced: true)
                    } else {
                        close(reason: "中转连接已断开：\(error.localizedDescription)")
                    }
                }
                return
            }
        }
    }

    private func drainOutgoing() async {
        defer { sendTask = nil }
        while !closed, !Task.isCancelled, !outgoing.isEmpty {
            let frame = outgoing.removeFirst()
            queuedBytes -= frame.byteCount
            do { try await socket?.send(frame.message) }
            catch { close(reason: "照片发送失败：\(error.localizedDescription)"); return }
        }
    }

    private func ping() {
        guard let socket, pendingPing == nil else { return }
        let id = UUID()
        pendingPing = id
        pingDeadline = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 10_000_000_000) } catch { return }
            guard self?.pendingPing == id else { return }
            self?.close(reason: "中转连接无响应，请重新连接。")
        }
        socket.sendPing { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self, !self.closed, self.pendingPing == id else { return }
                self.pendingPing = nil
                self.pingDeadline?.cancel()
                if let error { self.close(reason: "中转连接已断开：\(error.localizedDescription)") }
            }
        }
    }

    private func close(reason: String, replaced: Bool = false, authorizationRequired: Bool = false) {
        guard !closed else { return }
        closed = true
        peerReady = false
        _ = transferSlot.cancel()
        receiveTask?.cancel()
        sendTask?.cancel()
        pingTask?.cancel()
        pingDeadline?.cancel()
        handshakeDeadline?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
        session?.invalidateAndCancel()
        socket = nil
        session = nil
        receiveTask = nil
        sendTask = nil
        pingTask = nil
        pingDeadline = nil
        handshakeDeadline = nil
        outgoing.removeAll()
        queuedBytes = 0
        if authorizationRequired, let onAuthorizationRequired { onAuthorizationRequired(reason) }
        else if replaced { onReplaced?() }
        else { onClose?(reason) }
    }

    private struct TransferCommand: Encodable {
        let type: String
        let action: String
        let id: String
    }

    private struct ServerControl: Decodable {
        let type: String
        let peer: Bool?
        let transferControl: Bool?
        let id: UUID?
        let state: String?
    }
}
