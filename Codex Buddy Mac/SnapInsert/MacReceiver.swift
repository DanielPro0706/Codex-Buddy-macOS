import AppKit
@preconcurrency import ApplicationServices
import CoreImage.CIFilterBuiltins
import Observation

@Observable
@MainActor
final class MacReceiver {
    private(set) var isListening = false
    private(set) var isReceivingEnabled = false
    private(set) var connectionCount = 0
    private(set) var status = "正在启动…"
    private(set) var lastReceipt: String?
    private(set) var latestPreview: NSImage?
    private(set) var qrImage: NSImage?
    private(set) var computerName = "这台 Mac"
    private(set) var accessibilityGranted = AXIsProcessTrusted()
    private(set) var requiresInvitation = false
    private(set) var isRedeemingInvitation = false
    private(set) var invitationStatus: String?
    var automaticallyPaste: Bool {
        didSet { UserDefaults.standard.set(automaticallyPaste, forKey: "automaticallyPaste") }
    }

    private var identity: PairingInfo?
    var pairing: PairingInfo? { identity }
    @ObservationIgnored private var channels: [UUID: RelayChannel] = [:]
    @ObservationIgnored private var activity: [UUID: Date] = [:]
    @ObservationIgnored private var readyChannels: Set<UUID> = []
    @ObservationIgnored private var acceptedAt: [UUID: Date] = [:]
    @ObservationIgnored private var processed: [UUID: WireMessage] = [:]
    @ObservationIgnored private var processedOrder: [UUID] = []
    @ObservationIgnored private var processing: [UUID: [UUID: UUID]] = [:]
    @ObservationIgnored private var photoAuthorization = PhotoAuthorization()
    @ObservationIgnored private var latestPhoto: PreparedPhoto?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var watchdog: Timer?
    @ObservationIgnored private var sessionAvailable = true
    @ObservationIgnored private var displayAwake = true
    @ObservationIgnored private let keychainAccount = "mac-receiver-identity-v2"

    init() {
        automaticallyPaste = UserDefaults.standard.object(forKey: "automaticallyPaste") as? Bool ?? true
        observeSession()
        loadIdentityAndStart()
        watchdog = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.checkConnections() }
        }
    }

    func start() {
        guard !isReceivingEnabled, identity != nil else { return }
        isReceivingEnabled = true
        openRelay()
    }

    private func openRelay() {
        guard isReceivingEnabled, channels.isEmpty, let identity else { return }
        let expectedGeneration = generation
        let channelID = UUID()
        let channel = RelayChannel(pairing: identity, role: .mac)
        channels[channelID] = channel
        status = "正在连接阿里云加密中转…"
        channel.onReady = { [weak self] in
            guard let self, self.generation == expectedGeneration, self.channels[channelID] != nil else { return }
            self.isListening = true
            self.requiresInvitation = false
            self.connectionCount = 1
            self.status = "iPhone 已连接，可以拍照"
        }
        channel.onPeerUnavailable = { [weak self] in
            guard let self, self.generation == expectedGeneration else { return }
            self.photoAuthorization = PhotoAuthorization()
            self.requiresInvitation = false
            self.isListening = false
            self.connectionCount = 0
            self.status = "中转已连接，等待 iPhone 上线"
        }
        channel.onMessage = { [weak self] message in self?.receive(message, from: channelID) }
        channel.onClose = { [weak self] reason in
            guard let self, self.generation == expectedGeneration else { return }
            self.removeChannel(channelID)
            self.isListening = false
            self.status = "连接中断，正在重连…"
        }
        channel.onReplaced = { [weak self] in
            guard let self, self.generation == expectedGeneration else { return }
            self.stop()
            self.status = "已由另一台 Mac 接替，点击开始接收可重新连接"
        }
        channel.onAuthorizationRequired = { [weak self] reason in
            guard let self, self.generation == expectedGeneration else { return }
            self.removeChannel(channelID)
            self.isListening = false
            self.requiresInvitation = true
            self.status = "请在 iPhone 的 SnapInsert 设置确认账户额度或邀请码"
            self.invitationStatus = reason
        }
        channel.start()
    }

    func stop() {
        generation = UUID()
        let oldChannels = Array(channels.values)
        channels.removeAll()
        activity.removeAll()
        acceptedAt.removeAll()
        readyChannels.removeAll()
        processing.removeAll()
        photoAuthorization = PhotoAuthorization()
        oldChannels.forEach { $0.cancel() }
        isListening = false
        isReceivingEnabled = false
        connectionCount = 0
        status = "已暂停接收"
    }

    func toggleReceiving() {
        if !isReceivingEnabled {
            if identity == nil { loadIdentityAndStart() } else { start() }
        } else {
            stop()
        }
    }

    func rotatePairing() {
        guard !isRedeemingInvitation else { return }
        do {
            let newIdentity = try PairingInfo.create(name: computerName)
            try PairingStore.save(newIdentity, account: keychainAccount)
            let previousIdentity = identity
            stop()
            if let previousIdentity {
                UserDefaults.standard.removeObject(forKey: "receipts.\(previousIdentity.id.uuidString)")
            }
            identity = newIdentity
            processed.removeAll()
            processedOrder.removeAll()
            qrImage = makeQRCode(newIdentity.urlString)
            lastReceipt = "旧设备已解除配对，请用 iPhone 扫描新二维码。"
            start()
        } catch {
            lastReceipt = "未能重置配对：\(error.localizedDescription)"
        }
    }

    func redeemInvitation(_ code: String) async -> Bool {
        guard !isRedeemingInvitation, let identity else { return false }
        isRedeemingInvitation = true
        defer { isRedeemingInvitation = false }
        do {
            let request = try RelayInvitation.request(code: code, pairing: identity)
            stop()
            let expectedGeneration = generation
            invitationStatus = "正在激活中转服务…"
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil
            configuration.httpCookieStorage = nil
            configuration.urlCredentialStorage = nil
            let session = URLSession(configuration: configuration, delegate: InvitationRedirectPolicy(), delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            let (data, response) = try await session.data(for: request)
            try RelayInvitation.validateResponse(data: data, response: response)
            guard generation == expectedGeneration else { return false }
            requiresInvitation = false
            invitationStatus = "此配对已激活。请在 iPhone 扫描配对码。"
            start()
            return true
        } catch {
            invitationStatus = error.localizedDescription
            return false
        }
    }

    private final class InvitationRedirectPolicy: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    func refreshAccessibility() { accessibilityGranted = AXIsProcessTrusted() }

    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        accessibilityGranted = AXIsProcessTrustedWithOptions(options)
        if !accessibilityGranted,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func copyLatest() {
        guard let latestPhoto else { return }
        lastReceipt = ClipboardInsertion.copy(latestPhoto)
            ? "照片已重新复制，在目标位置按 ⌘V。"
            : "无法写入剪贴板，请稍后再试。"
    }

    private func loadIdentityAndStart() {
        do {
            if let existing = try PairingStore.load(account: keychainAccount) {
                identity = existing
            } else {
                let name = Host.current().localizedName ?? "我的 Mac"
                let created = try PairingInfo.create(name: name)
                try PairingStore.save(created, account: keychainAccount)
                identity = created
            }
            if let identity {
                computerName = identity.name
                qrImage = makeQRCode(identity.urlString)
                restoreReceipts()
            }
            start()
        } catch {
            status = "无法读取钥匙串：\(error.localizedDescription)"
        }
    }

    private func removeChannel(_ id: UUID) {
        channels[id] = nil
        photoAuthorization = PhotoAuthorization()
        activity[id] = nil
        acceptedAt[id] = nil
        readyChannels.remove(id)
        connectionCount = readyChannels.count
        if isListening, connectionCount == 0 { status = "等待 iPhone 连接" }
    }

    private func receive(_ message: WireMessage, from channelID: UUID) {
        guard channels[channelID] != nil else { return }
        activity[channelID] = Date()
        guard let attempt = message.attempt else {
            send(.receipt(id: message.id, status: "rejected", detail: "请更新 iPhone 上的 SnapInsert，再重新发送。"), to: channelID)
            return
        }
        if message.kind == .photoRequest {
            if let receipt = processed[message.id] {
                send(receipt, for: attempt, to: channelID)
            } else if let existingWaiters = processing[message.id] {
                // Retry the receipt on the new channel without starting a second paste.
                var waiters = existingWaiters.filter { channels[$0.key] != nil }
                waiters[channelID] = attempt
                processing[message.id] = waiters
            } else if let challenge = photoAuthorization.issue(for: message) {
                send(challenge, to: channelID)
            }
            return
        }
        guard let jpeg = message.jpeg, photoAuthorization.consume(message) else { return }
        guard processing.count < 2 else {
            send(.receipt(id: message.id, status: "rejected", detail: "正在处理照片，请稍候再试。", attempt: attempt),
                 to: channelID)
            return
        }
        processing[message.id] = [channelID: attempt]
        let expectedGeneration = generation
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Result { try PhotoPreparation.prepare(jpeg) }
            }.value
            guard let self, self.generation == expectedGeneration else { return }
            let waitingChannels = self.processing.removeValue(forKey: message.id) ?? [:]
            // A complete photo is committed once even if its original connection closes.
            // Only an explicit pause or pairing reset (generation change) cancels it.
            let receipt: WireMessage
            switch result {
            case .success(let photo):
                self.latestPhoto = photo
                self.latestPreview = NSImage(data: photo.previewPNG)
                self.refreshAccessibility()
                let outcome = ClipboardInsertion.receive(
                    photo,
                    automaticallyPaste: self.automaticallyPaste,
                    sessionAvailable: self.sessionAvailable && self.displayAwake
                )
                receipt = .receipt(id: message.id, status: outcome.status, detail: outcome.detail)
            case .failure(let error):
                receipt = .receipt(id: message.id, status: "rejected", detail: error.localizedDescription)
            }
            if receipt.status != "error" { self.remember(receipt) }
            self.lastReceipt = receipt.detail
            for (waitingChannel, attempt) in waitingChannels where self.channels[waitingChannel] != nil {
                self.send(receipt, for: attempt, to: waitingChannel)
            }
        }
    }

    private func send(_ receipt: WireMessage, for attempt: UUID, to channelID: UUID) {
        var reply = receipt
        reply.attempt = attempt
        send(reply, to: channelID)
    }

    private func send(_ message: WireMessage, to channelID: UUID) {
        do {
            try channels[channelID]?.send(message)
            activity[channelID] = Date()
        } catch {
            channels[channelID]?.cancel()
            removeChannel(channelID)
        }
    }

    private func remember(_ receipt: WireMessage) {
        processed[receipt.id] = receipt
        processedOrder.append(receipt.id)
        if processedOrder.count > 256 {
            let expired = processedOrder.removeFirst()
            processed[expired] = nil
        }
        persistReceipts()
    }

    private func restoreReceipts() {
        guard let identity,
              let data = UserDefaults.standard.data(forKey: "receipts.\(identity.id.uuidString)"),
              let receipts = try? JSONDecoder().decode([CachedReceipt].self, from: data) else { return }
        for receipt in receipts.suffix(256) {
            guard receipt.status == "pasted" || receipt.status == "clipboard" else { continue }
            let detail = receipt.status == "pasted"
                ? "这张照片此前已处理，不会重复发送粘贴指令。请在 Mac 的目标应用中确认。"
                : "这张照片此前已复制到 Mac。请确认当前剪贴板，再在目标位置手动粘贴。"
            processed[receipt.id] = .receipt(id: receipt.id, status: receipt.status, detail: detail)
            processedOrder.append(receipt.id)
        }
        // Also reduces any earlier full-message cache to receipt IDs/statuses only.
        persistReceipts()
    }

    private func persistReceipts() {
        guard let identity else { return }
        let cached = processedOrder.compactMap { id -> CachedReceipt? in
            guard let message = processed[id], let status = message.status,
                  status == "pasted" || status == "clipboard" else { return nil }
            return CachedReceipt(id: id, status: status)
        }
        if let data = try? JSONEncoder().encode(cached) {
            UserDefaults.standard.set(data, forKey: "receipts.\(identity.id.uuidString)")
        }
    }

    private struct CachedReceipt: Codable {
        let id: UUID
        let status: String
    }

    private func checkConnections() {
        refreshAccessibility()
        if isReceivingEnabled, channels.isEmpty { openRelay() }
    }

    private func observeSession() {
        let center = NSWorkspace.shared.notificationCenter
        let notifications: [(Notification.Name, @MainActor @Sendable (MacReceiver) -> Void)] = [
            (NSWorkspace.sessionDidResignActiveNotification, { $0.sessionAvailable = false }),
            (NSWorkspace.sessionDidBecomeActiveNotification, { $0.sessionAvailable = true }),
            (NSWorkspace.screensDidSleepNotification, { $0.displayAwake = false }),
            (NSWorkspace.screensDidWakeNotification, { $0.displayAwake = true }),
            (NSWorkspace.willSleepNotification, { $0.sessionAvailable = false }),
            (NSWorkspace.didWakeNotification, { $0.sessionAvailable = true })
        ]
        for (name, update) in notifications {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    update(self)
                }
            })
        }
    }

    private func makeQRCode(_ string: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let image = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 6, y: 6)),
              let cgImage = CIContext().createCGImage(image, from: image.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: image.extent.width, height: image.extent.height))
    }
}
