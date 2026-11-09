import AppKit
import Darwin
import Foundation
import OSLog

enum LocalCodexStatusError: LocalizedError {
    case executableNotFound
    case serviceEnded
    case invalidResponse
    case timeout
    case noCachedStatus
    case codexFolderAuthorizationRequired

    var errorDescription: String? {
        switch self {
        case .executableNotFound: "未找到 Codex 可执行文件"
        case .serviceEnded: "Codex 本地服务已结束"
        case .invalidResponse: "Codex 返回的状态格式无法识别"
        case .timeout: "读取 Codex 状态超时"
        case .noCachedStatus: "本机暂时没有可用的 Codex 状态记录"
        case .codexFolderAuthorizationRequired: "请先在设置中选择 .codex 文件夹"
        }
    }
}

actor LocalCodexStatusReader {
    private let executableURL: URL?
    private let requestTimeout: Duration
    private let allowsCachedFallback: Bool
    private let now: @Sendable () -> ContinuousClock.Instant
    private var session: CodexAppServerSession?
    private var readTask: Task<CodexStatusSnapshot, Error>?
    private var generation = 0
    private var consecutiveFailures = 0
    private var retryNotBefore: ContinuousClock.Instant?
    private var lastLiveError: Error?

    init(
        executableURL: URL? = nil,
        requestTimeout: Duration = .seconds(15),
        allowsCachedFallback: Bool = true,
        now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }
    ) {
        self.executableURL = executableURL
        self.requestTimeout = requestTimeout
        self.allowsCachedFallback = allowsCachedFallback
        self.now = now
    }

    func read(keepingSessionAlive: Bool = true) async throws -> CodexStatusSnapshot {
        if CodexFolderAccess.isSandboxed {
            guard let folderURL = CodexFolderAccess.authorizedFolderURL else {
                throw LocalCodexStatusError.codexFolderAuthorizationRequired
            }
            let didAccess = folderURL.startAccessingSecurityScopedResource()
            defer {
                if didAccess { folderURL.stopAccessingSecurityScopedResource() }
            }
            guard let snapshot = LocalCodexSessionLog.latestSnapshot(in: folderURL) else {
                throw LocalCodexStatusError.noCachedStatus
            }
            return snapshot
        }

        if let readTask { return try await readTask.value }
        let readGeneration = generation
        let task = Task { try await performLiveRead(keepingSessionAlive: keepingSessionAlive) }
        readTask = task
        defer {
            if generation == readGeneration { readTask = nil }
        }
        return try await task.value
    }

    /// Low-frequency checks must not leave the CLI's own background workers online.
    func suspend() {
        generation += 1
        readTask?.cancel()
        readTask = nil
        session?.stop()
        session = nil
    }

    private func performLiveRead(keepingSessionAlive: Bool) async throws -> CodexStatusSnapshot {
        try Task.checkCancellation()
        if let retryNotBefore, now() < retryNotBefore {
            if allowsCachedFallback, let cached = LocalCodexSessionLog.latestSnapshot() {
                return cached
            }
            throw lastLiveError ?? LocalCodexStatusError.serviceEnded
        }
        var usedSession: CodexAppServerSession?
        do {
            let current: CodexAppServerSession
            if let session {
                current = session
            } else {
                current = try CodexAppServerSession(
                    executableURL: executableURL,
                    requestTimeout: requestTimeout
                )
                session = current
            }
            usedSession = current
            let snapshot = try await current.readSnapshot()
            try Task.checkCancellation()
            consecutiveFailures = 0
            retryNotBefore = nil
            lastLiveError = nil
            if !keepingSessionAlive {
                current.stop()
                if session === current { session = nil }
            }
            return snapshot
        } catch {
            usedSession?.stop()
            if session === usedSession { session = nil }
            if Task.isCancelled { throw CancellationError() }
            // Authentication/network failures must not turn the normal refresh
            // timer back into a loop of expensive app-server initializations.
            consecutiveFailures = min(consecutiveFailures + 1, 6)
            lastLiveError = error
            if consecutiveFailures >= 2 {
                let seconds = min(300, 30 * (1 << (consecutiveFailures - 2)))
                retryNotBefore = now().advanced(by: .seconds(seconds))
            }
            if allowsCachedFallback, let cached = LocalCodexSessionLog.latestSnapshot() {
                return cached
            }
            throw error
        }
    }
}

enum CodexFolderAccess {
    nonisolated private static let bookmarkKey = "codexBuddy.authorizedCodexFolderBookmark"

    nonisolated static var isSandboxed: Bool {
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    }

    nonisolated static var authorizedFolderURL: URL? {
        guard let bookmark = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmark,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else { return nil }
        if isStale { try? saveBookmark(for: url) }
        return url
    }

    @MainActor
    static func chooseFolder() -> Bool {
        let panel = NSOpenPanel()
        panel.title = "选择 Codex 数据文件夹"
        panel.message = "请选择你的 .codex 文件夹，或直接选择其中的 sessions 文件夹。"
        panel.prompt = "授权读取"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.showsHiddenFiles = true
        let homeCodex = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex")
        if FileManager.default.fileExists(atPath: homeCodex.path) {
            panel.directoryURL = homeCodex
        }
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        do {
            try saveBookmark(for: url)
            return true
        } catch {
            return false
        }
    }

    nonisolated static func clear() {
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
    }

    nonisolated private static func saveBookmark(for url: URL) throws {
        let data = try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        UserDefaults.standard.set(data, forKey: bookmarkKey)
    }
}

nonisolated final class CodexAppServerSession: @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.danieldev.CodexBuddyNew", category: "quotaSession")
    private let process = Process()
    private let standardInput = Pipe()
    private let standardOutput = Pipe()
    private let stateLock = NSLock()
    private let writeLock = NSLock()
    private let requestTimeout: TimeInterval
    private let messageBuffer = NewlineMessageBuffer()
    private var initializationTask: Task<Void, Error>?
    private var pending: [Int: PendingRequest] = [:]
    private var terminalError: LocalCodexStatusError?
    private var requestID = 0

    init(executableURL: URL? = nil, requestTimeout: Duration = .seconds(15)) throws {
        let timeout = requestTimeout.components
        self.requestTimeout = max(0.001, Double(timeout.seconds) + Double(timeout.attoseconds) / 1e18)

        process.executableURL = try executableURL ?? URL(fileURLWithPath: Self.codexExecutable())
        process.arguments = ["-s", "read-only", "-a", "never", "app-server"]
        process.standardInput = standardInput
        process.standardOutput = standardOutput
        // An unread pipe fills with app-server diagnostics and blocks the RPC response.
        process.standardError = FileHandle.nullDevice
        // A CLI exiting between the liveness check and a write must fail the RPC,
        // rather than delivering SIGPIPE to the menu-bar application.
        _ = fcntl(standardInput.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)

        standardOutput.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                self.fail(.serviceEnded)
                return
            }
            for line in self.messageBuffer.append(data) {
                self.receive(line)
            }
        }
        try process.run()
        Self.logger.info("Started quota app-server pid=\(self.process.processIdentifier, privacy: .public)")
    }

    deinit {
        stop()
    }

    func readSnapshot() async throws -> CodexStatusSnapshot {
        do {
            try await initializeIfNeeded()
            let response = try await request(method: "account/rateLimits/read", params: nil)
            guard let result = response.value["result"] as? [String: Any] else {
                throw LocalCodexStatusError.invalidResponse
            }
            return try Self.snapshot(from: result)
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        fail(.serviceEnded)
    }

    private func initializeIfNeeded() async throws {
        let task: Task<Void, Error> = try stateLock.withLock {
            if let terminalError { throw terminalError }
            if let initializationTask { return initializationTask }
            let task = Task { [weak self] in
                guard let self else { throw LocalCodexStatusError.serviceEnded }
                _ = try await self.request(
                    method: "initialize",
                    params: ["clientInfo": ["name": "codex-buddy-new", "version": "1.0"]]
                )
                try self.send(["method": "initialized"])
            }
            initializationTask = task
            return task
        }
        try await task.value
    }

    private func request(method: String, params: [String: Any]?) async throws -> ResponseBox {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let id: Int
                do {
                    id = try stateLock.withLock {
                        if let terminalError { throw terminalError }
                        guard process.isRunning else { throw LocalCodexStatusError.serviceEnded }
                        requestID += 1
                        return requestID
                    }
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                let timeout = DispatchWorkItem { [weak self] in
                    self?.fail(.timeout, ifPendingRequest: id)
                }
                let registered = stateLock.withLock {
                    guard terminalError == nil else { return false }
                    pending[id] = PendingRequest(continuation: continuation, timeout: timeout)
                    return true
                }
                guard registered else {
                    continuation.resume(throwing: LocalCodexStatusError.serviceEnded)
                    return
                }
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + requestTimeout, execute: timeout)
                var payload: [String: Any] = ["id": id, "method": method]
                if let params { payload["params"] = params }
                do {
                    try send(payload)
                } catch {
                    fail(.serviceEnded)
                }
            }
        } onCancel: { [weak self] in
            self?.stop()
        }
    }

    private func receive(_ data: Data) {
        guard let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = (message["id"] as? NSNumber)?.intValue,
              let request = stateLock.withLock({ pending.removeValue(forKey: id) }) else {
            // This client only reads account status. Notifications are deliberately
            // discarded instead of accumulating in an unconsumed AsyncStream.
            return
        }
        request.timeout.cancel()
        if message["error"] != nil {
            request.continuation.resume(throwing: LocalCodexStatusError.invalidResponse)
        } else {
            request.continuation.resume(returning: ResponseBox(value: message))
        }
    }

    private func send(_ object: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        try writeLock.withLock {
            if let error = stateLock.withLock({ terminalError }) { throw error }
            try standardInput.fileHandleForWriting.write(contentsOf: data)
        }
    }

    private func fail(_ error: LocalCodexStatusError, ifPendingRequest id: Int? = nil) {
        let stopped: ([PendingRequest], Task<Void, Error>?)? = stateLock.withLock {
            guard terminalError == nil else { return nil }
            if let id, pending[id] == nil { return nil }
            terminalError = error
            let requests = Array(pending.values)
            pending.removeAll()
            let initialization = initializationTask
            initializationTask = nil
            return (requests, initialization)
        }
        guard let (requests, initialization) = stopped else { return }
        standardOutput.fileHandleForReading.readabilityHandler = nil
        Self.logger.info("Stopping quota app-server pid=\(self.process.processIdentifier, privacy: .public)")
        if process.isRunning { process.terminate() }
        writeLock.withLock { try? standardInput.fileHandleForWriting.close() }
        initialization?.cancel()
        for request in requests {
            request.timeout.cancel()
            request.continuation.resume(throwing: error)
        }
    }

    private static func codexExecutable() throws -> String {
        guard let path = CodexExecutableLocator.firstExecutablePath() else {
            throw LocalCodexStatusError.executableNotFound
        }
        return path
    }

    private static func snapshot(from payload: [String: Any]) throws -> CodexStatusSnapshot {
        let defaultLimits = payload["rateLimits"] as? [String: Any]
        let groupedLimits = payload["rateLimitsByLimitId"] as? [String: Any]
        let limits = (groupedLimits?["codex"] as? [String: Any]) ?? defaultLimits
        guard let limits else { throw LocalCodexStatusError.invalidResponse }

        let rawWindows = [limits["primary"], limits["secondary"]]
        let windows = rawWindows.enumerated().compactMap { index, value -> CodexUsageWindow? in
            guard let dictionary = value as? [String: Any],
                  let used = (dictionary["usedPercent"] as? NSNumber)?.intValue else { return nil }
            let duration = (dictionary["windowDurationMins"] as? NSNumber)?.intValue
            let resetSeconds = (dictionary["resetsAt"] as? NSNumber)?.doubleValue
            let reset = resetSeconds.map(Date.init(timeIntervalSince1970:))
            return CodexUsageWindow(
                kind: CodexStatusSnapshot.kind(forDuration: duration, fallbackIndex: index),
                usedPercent: used,
                durationMinutes: duration,
                resetsAt: reset
            )
        }
        guard !windows.isEmpty else { throw LocalCodexStatusError.invalidResponse }

        let credits = (limits["credits"] as? [String: Any])?["balance"] as? String
        let resetCredits = resetCredits(from: payload["rateLimitResetCredits"])
        return CodexStatusSnapshot(
            windows: windows,
            planName: limits["planType"] as? String,
            creditsBalance: credits,
            resetCredits: resetCredits,
            source: .appServer
        )
    }

    private static func resetCredits(from rawValue: Any?) -> CodexResetCreditsSummary? {
        guard let dictionary = rawValue as? [String: Any],
              let availableCount = (dictionary["availableCount"] as? NSNumber)?.intValue,
              availableCount >= 0 else { return nil }

        let credits: [CodexResetCredit]? = (dictionary["credits"] as? [[String: Any]])?.compactMap { value in
            guard let id = value["id"] as? String,
                  let status = value["status"] as? String else { return nil }
            let expiresAt = (value["expiresAt"] as? NSNumber)
                .map { Date(timeIntervalSince1970: $0.doubleValue) }
            return CodexResetCredit(
                id: id,
                title: value["title"] as? String,
                status: status,
                expiresAt: expiresAt
            )
        }

        return CodexResetCreditsSummary(
            availableCount: availableCount,
            credits: credits
        )
    }

    private struct ResponseBox: @unchecked Sendable {
        let value: [String: Any]
    }

    private struct PendingRequest: @unchecked Sendable {
        let continuation: CheckedContinuation<ResponseBox, Error>
        let timeout: DispatchWorkItem
    }
}

private nonisolated final class NewlineMessageBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()

    func append(_ incoming: Data) -> [Data] {
        lock.withLock {
            buffer.append(incoming)
            var lines: [Data] = []
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[..<newline]
                if !line.isEmpty { lines.append(Data(line)) }
                buffer.removeSubrange(...newline)
            }
            return lines
        }
    }
}

nonisolated enum CodexExecutableLocator {
    static let candidates = [
        "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
        "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex",
        "/Applications/ChatGPT.app/Contents/Resources/codex",
        "/Applications/Codex.app/Contents/Resources/codex",
        "/opt/homebrew/bin/codex",
        "/usr/local/bin/codex"
    ]

    static func firstExecutablePath(in paths: [String] = candidates) -> String? {
        paths.first(where: FileManager.default.isExecutableFile(atPath:))
    }
}

nonisolated enum LocalCodexSessionLog {
    static func latestSnapshot() -> CodexStatusSnapshot? {
        let configuredRoot = ProcessInfo.processInfo.environment["CODEX_HOME"]
            .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
        let codexRoot = configuredRoot
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex")
        return latestSnapshot(in: codexRoot.appending(path: "sessions"))
    }

    static func latestSnapshot(in authorizedFolder: URL) -> CodexStatusSnapshot? {
        let sessionsURL = authorizedFolder.lastPathComponent == "sessions"
            ? authorizedFolder
            : authorizedFolder.appending(path: "sessions")
        guard let enumerator = FileManager.default.enumerator(
            at: sessionsURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        let candidates = enumerator.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "jsonl" }
            .map { (url: $0, modifiedAt: modificationDate($0)) }
            .sorted { lhs, rhs in
                lhs.modifiedAt > rhs.modifiedAt
            }

        var newest: CodexStatusSnapshot?
        for candidate in candidates {
            // A rate-limit event cannot be newer than the last write to its log.
            // Once older files are reached, avoid rereading the entire history.
            if let newest, candidate.modifiedAt < newest.capturedAt { break }
            if let snapshot = snapshot(in: candidate.url),
               newest.map({ snapshot.capturedAt > $0.capturedAt }) ?? true {
                newest = snapshot
            }
        }
        return newest
    }

    private static func modificationDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    private static func snapshot(in url: URL) -> CodexStatusSnapshot? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let end = (try? handle.seekToEnd()) ?? 0
        let count = min(end, 1_500_000)
        try? handle.seek(toOffset: end - count)
        guard let data = try? handle.read(upToCount: Int(count)),
              let text = String(data: data, encoding: .utf8) else { return nil }

        let fractionalDateFormatter = ISO8601DateFormatter()
        fractionalDateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let dateFormatter = ISO8601DateFormatter()
        for line in text.split(separator: "\n").reversed() {
            guard let data = line.data(using: .utf8),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let payload = root["payload"] as? [String: Any],
                  payload["type"] as? String == "token_count",
                  let limits = payload["rate_limits"] as? [String: Any] else { continue }

            let rawWindows = [limits["primary"], limits["secondary"]]
            let windows = rawWindows.enumerated().compactMap { index, raw -> CodexUsageWindow? in
                guard let value = raw as? [String: Any],
                      let used = (value["used_percent"] as? NSNumber)?.intValue else { return nil }
                let duration = (value["window_minutes"] as? NSNumber)?.intValue
                let resetSeconds = (value["resets_at"] as? NSNumber)?.doubleValue
                let reset = resetSeconds.map(Date.init(timeIntervalSince1970:))
                return CodexUsageWindow(
                    kind: CodexStatusSnapshot.kind(forDuration: duration, fallbackIndex: index),
                    usedPercent: used,
                    durationMinutes: duration,
                    resetsAt: reset
                )
            }
            guard !windows.isEmpty else { continue }
            guard let timestamp = root["timestamp"] as? String,
                  let capturedAt = fractionalDateFormatter.date(from: timestamp)
                    ?? dateFormatter.date(from: timestamp) else { continue }
            return CodexStatusSnapshot(
                windows: windows,
                planName: limits["plan_type"] as? String,
                capturedAt: capturedAt,
                source: .sessionLog
            )
        }
        return nil
    }
}
