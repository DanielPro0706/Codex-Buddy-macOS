import Foundation
import Network
import Observation

@Observable
final class MacStatusStore {
    private static let automaticRefreshInterval: Duration = .seconds(15)
    var snapshot: CodexStatusSnapshot?
    var isRefreshing = false
    var statusText = "等待读取"
    var cloudStatus: CodexCloudSync.OperationStatus = .notChecked

    private var pollingTask: Task<Void, Never>?
    private var cloudPublishingTask: Task<Void, Never>?
    private var pendingCloudSnapshot: CodexStatusSnapshot?
    private var server: MacStatusServer?
    private let reader = LocalCodexStatusReader()

    init(previewSnapshot: CodexStatusSnapshot? = nil) {
        snapshot = previewSnapshot ?? CodexStatusCache.loadSnapshot()
    }

    var menuBarTitle: String {
        guard let snapshot else { return "Codex --" }
        return snapshot.windows
            .map { "\($0.kind.shortLabel) \($0.remainingPercent)%" }
            .joined(separator: " · ")
    }

    var pairingConnection: MacConnection {
        MacConnection(baseURL: localBaseURL, accessToken: serverToken)
    }

    var usesSandboxedFolderAccess: Bool { CodexFolderAccess.isSandboxed }

    var authorizedCodexFolderPath: String? {
        CodexFolderAccess.authorizedFolderURL?.path
    }

    func chooseCodexFolder() {
        guard CodexFolderAccess.chooseFolder() else { return }
        Task { await refresh() }
    }

    func clearCodexFolderAuthorization() {
        CodexFolderAccess.clear()
        statusText = "请重新选择 .codex 文件夹"
    }

    func start() {
        guard pollingTask == nil else { return }
        startServer()
        pollingTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: Self.automaticRefreshInterval)
            }
        }
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        statusText = "正在读取 Codex"
        defer { isRefreshing = false }

        do {
            let newSnapshot = try await reader.read()
            guard snapshot.map({ newSnapshot.capturedAt >= $0.capturedAt }) ?? true else {
                statusText = "读取到较旧记录，保留最新额度"
                return
            }
            snapshot = newSnapshot
            CodexStatusCache.save(snapshot: newSnapshot)
            statusText = newSnapshot.source == .sessionLog
                ? "已读取 Codex 日志记录"
                : "读取成功"
            publishToCloud(newSnapshot)
        } catch {
            statusText = error.localizedDescription
        }
    }

    private func publishToCloud(_ snapshot: CodexStatusSnapshot) {
        pendingCloudSnapshot = snapshot
        guard cloudPublishingTask == nil else { return }
        cloudPublishingTask = Task { [weak self] in
            guard let self else { return }
            defer { cloudPublishingTask = nil }
            while let next = pendingCloudSnapshot {
                pendingCloudSnapshot = nil
                cloudStatus = .checking
                cloudStatus = await CodexStatusClient.publishToCloud(next)
            }
        }
    }

    private var localBaseURL: URL {
        let deviceName = ProcessInfo.processInfo.hostName
        let host = deviceName.hasSuffix(".local") ? deviceName : "\(deviceName).local"
        return URL(string: "http://\(host):\(MacStatusServer.port.rawValue)")
            ?? URL(string: "http://localhost:\(MacStatusServer.port.rawValue)")!
    }

    private var serverToken: String {
        let key = "codexBuddyNew.serverToken"
        if let existing = UserDefaults.standard.string(forKey: key), !existing.isEmpty {
            return existing
        }
        let generated = (0 ..< 24)
            .map { _ in String(format: "%02x", UInt8.random(in: .min ... .max)) }
            .joined()
        UserDefaults.standard.set(generated, forKey: key)
        return generated
    }

    private func startServer() {
        let newServer = MacStatusServer(
            token: serverToken,
            snapshotProvider: { [weak self] in
                self?.snapshot
            }
        )
        do {
            try newServer.start()
            server = newServer
        } catch {
            statusText = "无法启动同步服务：\(error.localizedDescription)"
        }
    }
}
