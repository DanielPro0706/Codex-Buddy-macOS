import Foundation
import Network
import Observation
import OSLog

@Observable
final class MacStatusStore {
    private static let logger = Logger(subsystem: "com.danieldev.CodexBuddyNew", category: "refreshPolicy")
    var snapshot: CodexStatusSnapshot?
    var isRefreshing = false
    var statusText = "等待读取"
    var cloudStatus: CodexCloudSync.OperationStatus = .notChecked

    private var pollingTask: Task<Void, Never>?
    private var cloudPublishingTask: Task<Void, Never>?
    private var pendingCloudSnapshot: CodexStatusSnapshot?
    private var server: MacStatusServer?
    private var lastCloudPublishedAt: Date?
    private let reader = LocalCodexStatusReader()
    // Sandbox authorization covers quota log reads, not other processes' writer
    // descriptors. Keep activity unknown rather than claiming whole-machine idle.
    @ObservationIgnored private let environmentMonitor = MacRefreshEnvironmentMonitor(
        activityMonitoringEnabled: !CodexFolderAccess.isSandboxed
    )
    @ObservationIgnored private var refreshPolicy = MacRefreshPolicy()
    @ObservationIgnored private var pollingGeneration = 0
    @ObservationIgnored private var pollingKeepsSessionAlive = true
    @ObservationIgnored private var started = false
    @ObservationIgnored private var lastLoggedPolicy: String?

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
        guard !started else { return }
        started = true
        startServer()
        environmentMonitor.start { [weak self] environment in
            self?.environmentDidChange(environment)
        }
        restartPolling(immediately: refreshPolicy.phase == .normal)
    }

    func stop() {
        started = false
        pollingGeneration += 1
        pollingTask?.cancel()
        pollingTask = nil
        environmentMonitor.stop()
        server?.stop()
        server = nil
        cloudPublishingTask?.cancel()
        pendingCloudSnapshot = nil
        Task { [reader] in await reader.suspend() }
    }

    private func environmentDidChange(_ environment: MacRefreshEnvironment) {
        let previous = refreshPolicy.environment
        let previousInterval = refreshPolicy.interval
        refreshPolicy.update(environment: environment)
        guard started, pollingTask != nil else { return }
        let displayWoke = previous.allDisplaysAsleep && !environment.allDisplaysAsleep
        if previousInterval != refreshPolicy.interval || displayWoke {
            restartPolling(immediately: refreshPolicy.phase == .normal)
        }
    }

    private func restartPolling(immediately: Bool) {
        logRefreshPolicy()
        let previousTask = pollingTask
        let previousKeptSessionAlive = pollingKeepsSessionAlive
        previousTask?.cancel()
        pollingGeneration += 1
        let generation = pollingGeneration
        pollingKeepsSessionAlive = refreshPolicy.phase == .normal
        let keepsSessionAlive = pollingKeepsSessionAlive
        pollingTask = Task { [weak self, previousTask] in
            guard let self else { return }
            // Closing the quota client also stops the CLI's autonomous catalog
            // workers while the displays are off and conversations are idle.
            if !keepsSessionAlive || !previousKeptSessionAlive {
                await reader.suspend()
            }
            await previousTask?.value
            var shouldWait = !immediately
            while started && !Task.isCancelled && pollingGeneration == generation {
                if shouldWait {
                    do {
                        try await Task.sleep(for: refreshPolicy.nextDelay())
                    } catch {
                        return
                    }
                }
                guard started, !Task.isCancelled, pollingGeneration == generation else { return }
                if refreshPolicy.phase != .normal {
                    // The hourly phase requires a fresh local environment check;
                    // normal 15-second reads rely on the event-driven monitor.
                    await environmentMonitor.refresh()
                    guard !Task.isCancelled, pollingGeneration == generation else { return }
                }
                refreshPolicy.didPerformScheduledCheck(environment: environmentMonitor.current)
                logRefreshPolicy()
                await refresh()
                shouldWait = true
            }
        }
    }

    private func logRefreshPolicy() {
        let phase = String(describing: refreshPolicy.phase)
        let seconds = refreshPolicy.interval.components.seconds
        let marker = "\(phase):\(seconds)"
        guard marker != lastLoggedPolicy else { return }
        lastLoggedPolicy = marker
        Self.logger.info("Quota refresh mode=\(phase, privacy: .public) intervalSeconds=\(seconds, privacy: .public)")
    }

    /// A maintenance wake can leave every display asleep. Only a genuine normal
    /// environment should bypass the existing idle deadline.
    func refreshForWake() async {
        guard started else { return }
        await environmentMonitor.refresh()
        guard started, refreshPolicy.phase == .normal else { return }
        await refresh()
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        statusText = "正在读取 Codex"
        defer { isRefreshing = false }

        do {
            let newSnapshot = try await reader.read(keepingSessionAlive: refreshPolicy.phase == .normal)
            try Task.checkCancellation()
            guard snapshot.map({ newSnapshot.capturedAt >= $0.capturedAt }) ?? true else {
                statusText = "读取到较旧记录，保留最新额度"
                return
            }
            let shouldPublishCloud = Self.shouldPublishCloud(
                previous: snapshot,
                lastPublishedAt: lastCloudPublishedAt,
                next: newSnapshot
            )
            snapshot = newSnapshot
            CodexStatusCache.save(snapshot: newSnapshot)
            statusText = newSnapshot.source == .sessionLog
                ? "已读取 Codex 日志记录"
                : "读取成功"
            if shouldPublishCloud {
                lastCloudPublishedAt = .now
                publishToCloud(newSnapshot)
            }
        } catch is CancellationError {
            return
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

    private static func shouldPublishCloud(
        previous: CodexStatusSnapshot?,
        lastPublishedAt: Date?,
        next: CodexStatusSnapshot
    ) -> Bool {
        guard let previous else { return true }
        let valuesChanged = previous.windows != next.windows
            || previous.planName != next.planName
            || previous.creditsBalance != next.creditsBalance
            || previous.resetCredits != next.resetCredits
        return valuesChanged || lastPublishedAt.map { Date.now.timeIntervalSince($0) >= 5 * 60 } ?? true
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
