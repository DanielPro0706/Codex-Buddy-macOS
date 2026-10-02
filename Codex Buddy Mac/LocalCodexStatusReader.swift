import AppKit
import Foundation

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
    func read() async throws -> CodexStatusSnapshot {
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

        do {
            return try await CodexAppServerSession().readSnapshot()
        } catch {
            if let cached = LocalCodexSessionLog.latestSnapshot() {
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
    private let process = Process()
    private let standardInput = Pipe()
    private let standardOutput = Pipe()
    private let messages: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation
    private var requestID = 0

    init(executableURL: URL? = nil) throws {
        var streamContinuation: AsyncStream<Data>.Continuation!
        let stream = AsyncStream<Data> { streamContinuation = $0 }
        continuation = streamContinuation
        messages = stream

        process.executableURL = try executableURL ?? URL(fileURLWithPath: Self.codexExecutable())
        process.arguments = ["-s", "read-only", "-a", "never", "app-server"]
        process.standardInput = standardInput
        process.standardOutput = standardOutput
        // An unread pipe fills with app-server diagnostics and blocks the RPC response.
        process.standardError = FileHandle.nullDevice

        let buffer = NewlineMessageBuffer()
        let continuation = continuation
        standardOutput.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                continuation.finish()
                return
            }
            for line in buffer.append(data) {
                continuation.yield(line)
            }
        }
        try process.run()
    }

    deinit {
        standardOutput.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { process.terminate() }
    }

    func readSnapshot() async throws -> CodexStatusSnapshot {
        defer { stop() }
        _ = try await request(
            method: "initialize",
            params: ["clientInfo": ["name": "codex-buddy-new", "version": "1.0"]]
        )
        try send(["method": "initialized"])
        let response = try await request(method: "account/rateLimits/read", params: nil)
        guard let result = response["result"] as? [String: Any] else {
            throw LocalCodexStatusError.invalidResponse
        }
        return try Self.snapshot(from: result)
    }

    private func request(method: String, params: [String: Any]?) async throws -> [String: Any] {
        requestID += 1
        let currentID = requestID
        var payload: [String: Any] = ["id": currentID, "method": method]
        if let params { payload["params"] = params }
        try send(payload)

        return try await withThrowingTaskGroup(of: ResponseBox.self) { group in
            group.addTask { [self] in
                for await data in messages {
                    guard let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          (message["id"] as? NSNumber)?.intValue == currentID else { continue }
                    if message["error"] != nil { throw LocalCodexStatusError.invalidResponse }
                    return ResponseBox(value: message)
                }
                throw LocalCodexStatusError.serviceEnded
            }
            group.addTask {
                try await Task.sleep(for: .seconds(15))
                throw LocalCodexStatusError.timeout
            }
            guard let first = try await group.next() else { throw LocalCodexStatusError.serviceEnded }
            group.cancelAll()
            return first.value
        }
    }

    private func send(_ object: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        try standardInput.fileHandleForWriting.write(contentsOf: data)
    }

    private func stop() {
        standardOutput.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { process.terminate() }
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
        latestSnapshot(
            in: FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex")
        )
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
