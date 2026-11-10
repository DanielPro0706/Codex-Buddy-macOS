import Foundation
import Network
import Security

nonisolated enum TransportSecurity {
    static func parameters(for pairing: PairingInfo) -> NWParameters {
        let options = NWProtocolTLS.Options()
        // Network's TLS-PSK implementation supports TLS 1.2, not TLS 1.3.
        sec_protocol_options_set_min_tls_protocol_version(options.securityProtocolOptions, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(options.securityProtocolOptions, .TLSv12)
        sec_protocol_options_append_tls_ciphersuite(
            options.securityProtocolOptions,
            tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!
        )
        let identity = Data(pairing.id.uuidString.utf8)
        let secretData = pairing.key.withUnsafeBytes { DispatchData(bytes: $0) }
        let identityData = identity.withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(options.securityProtocolOptions,
                                                secretData as __DispatchData, identityData as __DispatchData)
        sec_protocol_options_set_tls_pre_shared_key_identity_hint(options.securityProtocolOptions,
                                                                  identityData as __DispatchData)
        let parameters = NWParameters(tls: options, tcp: NWProtocolTCP.Options())
        parameters.includePeerToPeer = true
        return parameters
    }
}

@MainActor
final class SecureChannel {
    var onMessage: ((WireMessage) -> Void)?
    var onReady: (() -> Void)?
    var onClose: ((String) -> Void)?

    private let connection: NWConnection
    private var ready = false
    private var closed = false
    private var started = false
    private var deadline: Task<Void, Never>?

    init(connection: NWConnection) { self.connection = connection }

    func start() {
        guard !started, !closed else { return }
        started = true
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self, !self.closed else { return }
                switch state {
                case .ready:
                    self.ready = true
                    self.deadline?.cancel()
                    self.onReady?()
                    self.receiveHeader()
                case .failed(let error): self.close(reason: error.localizedDescription)
                case .cancelled: self.close(reason: "连接已断开。")
                default: break
                }
            }
        }
        armDeadline(seconds: 15)
        connection.start(queue: .main)
    }

    func send(_ message: WireMessage) throws {
        guard ready, !closed else { throw WireError.notReady }
        let frame = try WireFrame.encode(message)
        connection.send(content: frame, completion: .contentProcessed { [weak self] error in
            guard let error else { return }
            Task { @MainActor [weak self] in self?.close(reason: error.localizedDescription) }
        })
    }

    func cancel() { close(reason: "连接已断开。") }

    private func receiveHeader(prefix: Data = Data()) {
        guard !closed else { return }
        // Idle connections may stay open, but once a frame starts all its bytes must arrive in time.
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4 - prefix.count) { [weak self] data, _, complete, error in
            Task { @MainActor [weak self] in
                guard let self, !self.closed else { return }
                if let error { self.close(reason: error.localizedDescription); return }
                guard let data, !data.isEmpty else {
                    self.close(reason: complete ? "连接已断开。" : "收到的消息头不完整。")
                    return
                }
                if prefix.isEmpty { self.armDeadline(seconds: 30) }
                let header = prefix + data
                guard header.count == 4 else {
                    if complete { self.close(reason: "收到的消息头不完整。") }
                    else { self.receiveHeader(prefix: header) }
                    return
                }
                do {
                    let length = try WireFrame.payloadLength(header: header)
                    self.armDeadline(seconds: 30)
                    self.receivePayload(length: length)
                } catch { self.close(reason: error.localizedDescription) }
            }
        }
    }

    private func receivePayload(length: Int) {
        connection.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] data, _, complete, error in
            Task { @MainActor [weak self] in
                guard let self, !self.closed else { return }
                self.deadline?.cancel()
                if let error { self.close(reason: error.localizedDescription); return }
                guard let data, data.count == length else { self.close(reason: "图片传输中断，请重新发送。"); return }
                do {
                    let message = try WireFrame.decode(payload: data)
                    self.onMessage?(message)
                    if complete { self.close(reason: "连接已断开。") }
                    else { self.receiveHeader() }
                } catch { self.close(reason: error.localizedDescription) }
            }
        }
    }

    private func armDeadline(seconds: UInt64) {
        deadline?.cancel()
        deadline = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: seconds * 1_000_000_000) }
            catch { return }
            self?.close(reason: WireError.timeout.localizedDescription)
        }
    }

    private func close(reason: String) {
        guard !closed else { return }
        closed = true
        ready = false
        deadline?.cancel()
        deadline = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
        onClose?(reason)
    }
}
