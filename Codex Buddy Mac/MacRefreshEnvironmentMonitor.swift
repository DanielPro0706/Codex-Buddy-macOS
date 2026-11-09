import AppKit
import CoreGraphics
import CoreServices
import Foundation
import SQLite3

/// Observes local power/display/session signals and saved turns in one Codex home.
/// Missing, unreadable, truncated, or unsupported activity evidence stays unknown.
@MainActor
final class MacRefreshEnvironmentMonitor {
    private(set) var current: MacRefreshEnvironment = .unknown

    private let activityIndex: MacCodexActivityIndex
    private let displaySignals = MacPowerDisplaySignals()
    private let codexHome: URL
    private let activityMonitoringEnabled: Bool
    private var onChange: (@MainActor (MacRefreshEnvironment) -> Void)?
    private var observers: [NSObjectProtocol] = []
    private var fileEvents: MacSessionFileEvents?
    private var scanTask: Task<Void, Never>?
    private var inventoryTimer: Task<Void, Never>?
    private var displayRecheck: Task<Void, Never>?
    private var pendingPaths = Set<String>()
    private var needsFullScan = false
    private var needsInventoryScan = false
    private var started = false
    private var generation: UInt64 = 0
    private var displayCallbackRegistered = false

    nonisolated static var defaultCodexHome: URL {
        if let configured = ProcessInfo.processInfo.environment["CODEX_HOME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !configured.isEmpty {
            return URL(fileURLWithPath: configured, isDirectory: true).standardizedFileURL
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    }

    init(codexHome: URL? = nil, activityMonitoringEnabled: Bool = true) {
        let resolved = (codexHome ?? Self.defaultCodexHome).standardizedFileURL
        self.codexHome = resolved
        self.activityMonitoringEnabled = activityMonitoringEnabled
        activityIndex = MacCodexActivityIndex(codexHome: resolved)
    }

    func start(onChange: @escaping @MainActor (MacRefreshEnvironment) -> Void) {
        guard !started else { return }
        generation &+= 1
        started = true
        self.onChange = onChange
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [
            NSWorkspace.screensDidSleepNotification,
            NSWorkspace.screensDidWakeNotification,
            NSWorkspace.didWakeNotification
        ] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let isWake = note.name == NSWorkspace.screensDidWakeNotification
                let isSystemWake = note.name == NSWorkspace.didWakeNotification
                Task { @MainActor [weak self] in
                    self?.displayStateChanged(isWake: isWake)
                    if isSystemWake {
                        self?.scheduleActivityScan(paths: [], full: true, poll: true)
                    }
                }
            })
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: MacRefreshScreenSignals.configurationChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.displayStateChanged(isWake: false) }
        })
        displayCallbackRegistered = CGDisplayRegisterReconfigurationCallback(
            MacRefreshScreenSignals.callback, nil
        ) == .success

        if activityMonitoringEnabled {
            fileEvents = MacSessionFileEvents(root: codexHome.path) { [weak self] paths, rescan in
                Task { @MainActor [weak self] in
                    self?.scheduleActivityScan(paths: paths, full: rescan)
                }
            }
        }
        displaySignals.start { [weak self] in self?.sampleDisplays() }
        // Establish the recursive listener before the initial scan so a new turn
        // cannot be missed between taking a snapshot and beginning observation.
        sampleDisplays()
        onChange(current)
        if shouldWatchActivity { scheduleActivityScan(paths: [], full: true, poll: true) }
    }

    func stop() {
        guard started else { return }
        started = false
        generation &+= 1
        scanTask?.cancel()
        scanTask = nil
        inventoryTimer?.cancel()
        inventoryTimer = nil
        displayRecheck?.cancel()
        displayRecheck = nil
        fileEvents?.stop()
        fileEvents = nil
        displaySignals.stop()
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
        if displayCallbackRegistered {
            CGDisplayRemoveReconfigurationCallback(MacRefreshScreenSignals.callback, nil)
            displayCallbackRegistered = false
        }
        pendingPaths.removeAll()
        needsFullScan = false
        needsInventoryScan = false
        onChange = nil
    }

    /// Await this before confirming an idle scheduled check.
    func refresh() async {
        guard started else { return }
        displaySignals.refresh()
        sampleDisplays()
        guard shouldWatchActivity else { return }
        scheduleActivityScan(paths: [], full: true, poll: true)
        await scanTask?.value
    }

    private func displayStateChanged(isWake: Bool) {
        guard started else { return }
        displaySignals.refresh()
        // Waking any display is enough to leave backoff immediately. Sleep and
        // reconfiguration notifications still require querying every display.
        if isWake {
            var updated = current
            updated.allDisplaysAsleep = false
            publish(updated)
        } else {
            sampleDisplays()
        }
        displayRecheck?.cancel()
        displayRecheck = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled, let self, started else { return }
            displaySignals.refresh()
            sampleDisplays()
        }
    }

    private func sampleDisplays() {
        guard started else { return }
        // A failed query never establishes the all-displays-asleep condition.
        let asleep = Self.allOnlineDisplaysAsleep() ?? false
        let wasWatching = shouldWatchActivity
        let signals = displaySignals.current
        var updated = current
        updated.allDisplaysAsleep = asleep
        updated.isOnACPower = signals.isOnACPower
        updated.isPowerSourceKnown = signals.isPowerSourceKnown
        updated.lidClosed = signals.lidClosed
        updated.hasExternalDisplay = signals.hasExternalDisplay
        updated.isScreenLocked = signals.isScreenLocked
        updated.isScreenSaverRunning = signals.isScreenSaverRunning
        updated.allExternalDisplaysAsleep = signals.allExternalDisplaysAsleep
        publish(updated)
        if shouldWatchActivity {
            if !wasWatching { scheduleActivityScan(paths: [], full: true, poll: true) }
            if inventoryTimer == nil {
                inventoryTimer = Task { [weak self] in
                    while !Task.isCancelled {
                        guard self?.requestInventorySampleIfSleeping() == true else { return }
                        try? await Task.sleep(for: .seconds(2))
                    }
                }
            }
        } else {
            inventoryTimer?.cancel()
            inventoryTimer = nil
        }
    }

    private func requestInventorySampleIfSleeping() -> Bool {
        guard started else { return false }
        displaySignals.refresh()
        sampleDisplays()
        guard shouldWatchActivity else { return false }
        scheduleActivityScan(paths: [], full: false, poll: true)
        return true
    }

    private var shouldWatchActivity: Bool {
        activityMonitoringEnabled && (
            current.isIdleEligible || current.isScreenLocked || current.isScreenSaverRunning || current.lidClosed
        )
    }

    private static func allOnlineDisplaysAsleep() -> Bool? {
        for _ in 0..<3 {
            var count: UInt32 = 0
            guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return nil }
            var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
            var actual: UInt32 = 0
            guard CGGetOnlineDisplayList(count, &displays, &actual) == .success, actual > 0 else { return nil }
            var checkedCount: UInt32 = 0
            guard CGGetOnlineDisplayList(0, nil, &checkedCount) == .success else { return nil }
            guard actual == checkedCount else { continue } // Hot-plug raced enumeration.
            return displays.prefix(Int(actual)).allSatisfy { CGDisplayIsAsleep($0) != 0 }
        }
        return nil
    }

    private func scheduleActivityScan(paths: [String], full: Bool, poll: Bool = false) {
        guard started, activityMonitoringEnabled else { return }
        pendingPaths.formUnion(paths)
        needsFullScan = needsFullScan || full
        needsInventoryScan = needsInventoryScan || poll
        // While the machine is plainly in use, defer broad metadata scans.
        // Actual rollout changes can still update activity immediately.
        guard shouldWatchActivity || paths.contains(where: { $0.hasSuffix(".jsonl") }) else { return }
        guard scanTask == nil else { return }
        let scanGeneration = generation
        scanTask = Task { [weak self] in
            guard let self else { return }
            while started && generation == scanGeneration && (needsFullScan || needsInventoryScan || !pendingPaths.isEmpty) {
                let full = needsFullScan
                let paths = pendingPaths
                needsFullScan = false
                needsInventoryScan = false
                pendingPaths.removeAll()
                let activity = await activityIndex.scan(changedPaths: paths, full: full)
                guard !Task.isCancelled, started, generation == scanGeneration else { break }
                // Without working notifications a new turn could go undetected.
                let safeActivity = fileEvents == nil ? MacCodexActivity.unknown : activity
                var updated = current
                updated.activity = safeActivity
                publish(updated)
            }
            if generation == scanGeneration { scanTask = nil }
        }
    }

    private func publish(_ environment: MacRefreshEnvironment) {
        guard current != environment else { return }
        current = environment
        onChange?(environment)
    }
}

private nonisolated enum MacRefreshScreenSignals {
    static let configurationChanged = Notification.Name("com.danieldev.CodexBuddy.displayConfigurationChanged")
    static let callback: CGDisplayReconfigurationCallBack = { _, flags, _ in
        guard !flags.contains(.beginConfigurationFlag) else { return }
        NotificationCenter.default.post(name: configurationChanged, object: nil)
    }
}

/// Reads only lifecycle event type/turn identity. It never returns message text.
nonisolated enum MacCodexRolloutLifecycle {
    static func activity(
        at url: URL,
        expectedThreadID: String? = nil,
        maximumScanBytes: Int = 256 * 1024 * 1024
    ) -> MacCodexActivity {
        snapshot(at: url, expectedThreadID: expectedThreadID, maximumScanBytes: maximumScanBytes).activity
    }

    static func snapshot(
        at url: URL,
        continuing previous: MacCodexRolloutSnapshot? = nil,
        expectedThreadID: String? = nil,
        maximumScanBytes: Int = 256 * 1024 * 1024
    ) -> MacCodexRolloutSnapshot {
        let unknown = MacCodexRolloutSnapshot(completeHistory: false, expectedThreadID: expectedThreadID)
        guard maximumScanBytes > 0 else { return unknown }
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let length = try handle.seekToEnd()
            var result = previous.flatMap { $0.offset <= length ? $0 : nil }
                ?? MacCodexRolloutSnapshot(completeHistory: true, expectedThreadID: expectedThreadID)
            var start = result.offset
            if length - start > UInt64(maximumScanBytes) {
                start = length - UInt64(maximumScanBytes)
                result = MacCodexRolloutSnapshot(completeHistory: false, expectedThreadID: expectedThreadID)
                result.discardPartialLine = true
            }
            try handle.seek(toOffset: start)
            while start < length {
                let count = Int(min(64 * 1024, length - start))
                guard let data = try handle.read(upToCount: count), !data.isEmpty else { return unknown }
                // Bound memory by one line, independently of the total history limit.
                result.append(data, maximumPendingBytes: 128 * 1024 * 1024)
                start += UInt64(data.count)
            }
            result.offset = length
            return result
        } catch {
            return unknown
        }
    }
}

/// A complete replay pairs turns by ID; append-only updates retain only this
/// small state and an incomplete line, never prior conversation text.
nonisolated struct MacCodexRolloutSnapshot: Sendable {
    var offset: UInt64 = 0
    var discardPartialLine = false
    private var activeTurns = Set<String>()
    private var hasLifecycle = false
    private var uncertain = false
    private var completeHistory: Bool
    private var pending = Data()
    private let expectedThreadID: String?
    private var matchingSessionMetadata = false
    private var childHistoryStart: UInt64?
    private var lastOrdinal: UInt64?

    init(completeHistory: Bool, expectedThreadID: String? = nil) {
        self.completeHistory = completeHistory
        self.expectedThreadID = expectedThreadID?.lowercased()
    }

    var activity: MacCodexActivity {
        guard completeHistory, !uncertain, pending.isEmpty, !discardPartialLine else { return .unknown }
        if !activeTurns.isEmpty { return .active }
        if let childHistoryStart, (lastOrdinal ?? 0) < childHistoryStart - 1 { return .unknown }
        // A saved/forked context can exist before its first turn. It is idle only
        // after a complete, valid replay whose session metadata matches its ID.
        return hasLifecycle || matchingSessionMetadata ? .inactive : .unknown
    }

    mutating func append(_ data: Data, maximumPendingBytes: Int) {
        let previousCount = pending.count
        pending.append(data)
        // The retained prefix has already been searched. Searching only the
        // appended bytes avoids quadratic scans of a large partial JSON line.
        var searchStart = pending.index(pending.startIndex, offsetBy: previousCount)
        while let newline = pending.range(of: Data([0x0A]), in: searchStart..<pending.endIndex) {
            let line = pending[..<newline.lowerBound]
            if discardPartialLine {
                discardPartialLine = false
            } else {
                autoreleasepool { consume(line) }
            }
            let consumed = pending.distance(from: pending.startIndex, to: newline.upperBound)
            if consumed >= 1024 * 1024 {
                // Do not retain a completed image/tool payload's large backing
                // allocation in every cached session snapshot.
                let remaining = pending.count - consumed
                pending = pending.withUnsafeBytes { bytes in
                    guard remaining > 0 else { return Data() }
                    return Data(bytes: bytes.baseAddress!.advanced(by: consumed), count: remaining)
                }
            } else {
                pending.removeSubrange(pending.startIndex..<newline.upperBound)
            }
            searchStart = pending.startIndex
        }
        if pending.count > maximumPendingBytes {
            uncertain = true
            pending.removeAll(keepingCapacity: false)
            discardPartialLine = true
        }
    }

    private mutating func consume(_ line: Data.SubSequence) {
        guard !line.isEmpty else { uncertain = true; return }
        // Validate every line, including context-only fork history. Do not retain
        // or expose message fields after this short-lived decoding scope.
        guard let event = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else {
            uncertain = true
            return
        }
        let ordinal = event["ordinal"] as? UInt64
        if let ordinal {
            if let lastOrdinal, ordinal <= lastOrdinal { uncertain = true }
            lastOrdinal = ordinal
        } else if childHistoryStart != nil {
            uncertain = true
        }
        if let childHistoryStart, matchingSessionMetadata,
           let ordinal, ordinal > 0, ordinal < childHistoryStart {
            // This is inherited parent context. Its parent session_meta and
            // task lifecycle must not affect the child's identity or activity.
            return
        }
        if event["type"] as? String == "session_meta" {
            let payload = event["payload"] as? [String: Any]
            let id = payload?["id"] as? String
            if let expectedThreadID {
                if id?.lowercased() == expectedThreadID {
                    matchingSessionMetadata = true
                    if let rawStart = payload?["subagent_history_start_ordinal"] {
                        if let start = rawStart as? UInt64, start > 0, ordinal == 0 {
                            childHistoryStart = start
                        } else {
                            uncertain = true
                        }
                    }
                } else {
                    uncertain = true
                }
            }
            return
        }
        guard line.containsLifecycleMarker else { return }
        guard event["type"] as? String == "event_msg" else { return }
        guard let payload = event["payload"] as? [String: Any],
              let type = payload["type"] as? String else { uncertain = true; return }
        guard ["task_started", "task_complete", "turn_aborted"].contains(type) else { return }
        hasLifecycle = true
        guard let turnID = payload["turn_id"] as? String, !turnID.isEmpty else { uncertain = true; return }
        if type == "task_started" {
            activeTurns.insert(turnID)
        } else if activeTurns.remove(turnID) == nil {
            // A terminal event whose start was not observed cannot establish idle.
            uncertain = true
        }
    }
}

private nonisolated extension Data.SubSequence {
    var containsLifecycleMarker: Bool {
        ["\"task_started\"", "\"task_complete\"", "\"turn_aborted\""].contains {
            range(of: Data($0.utf8)) != nil
        }
    }
}

nonisolated struct MacCodexActivitySummary: Equatable, Sendable {
    var active = 0
    var inactive = 0
    var unknown = 0
    var outOfScope = 0
    var inventoryComplete = false

    var activity: MacCodexActivity {
        if active > 0 { return .active }
        if !inventoryComplete || unknown > 0 { return .unknown }
        return .inactive
    }
}

actor MacCodexActivityIndex {
    private struct RegisteredRollout {
        var path: String
        var supported: Bool
    }

    private struct CachedFile {
        var threadID: String
        var size: UInt64
        var identity: UInt64
        var modified: Date
        var snapshot: MacCodexRolloutSnapshot
    }

    private let codexHome: URL
    private let inventory: @Sendable (URL) -> MacCodexWriterInventory
    private var registered: [String: RegisteredRollout] = [:]
    private var files: [String: CachedFile] = [:]
    private var registeredIndexKnown = false
    private var previousWriterIDs = Set<String>()
    private var discoveredPaths: [String: Set<String>] = [:]
    private var filenameIndexKnown = false
    private(set) var lastSummary = MacCodexActivitySummary()

    init(
        codexHome: URL,
        inventory: @escaping @Sendable (URL) -> MacCodexWriterInventory = {
            MacCodexWriterInventory.capture(codexHome: $0)
        }
    ) {
        self.codexHome = codexHome
        self.inventory = inventory
    }

    func scan(changedPaths: Set<String>, full: Bool) -> MacCodexActivity {
        let writers = inventory(codexHome)
        var summary = MacCodexActivitySummary(inventoryComplete: writers.isComplete)
        if writers.threadIDs.isEmpty {
            files.removeAll(keepingCapacity: true)
            previousWriterIDs = []
            lastSummary = summary
            return summary.activity
        }

        let metadataChanged = changedPaths.contains {
            $0.hasSuffix("/state_5.sqlite") || $0.hasSuffix("/state_5.sqlite-wal")
        }
        let newWriters = !writers.threadIDs.subtracting(previousWriterIDs).isEmpty
        previousWriterIDs = writers.threadIDs
        if full || metadataChanged || !registeredIndexKnown || newWriters {
            do {
                registered = try registeredRollouts()
                registeredIndexKnown = true
            } catch {
                registeredIndexKnown = false
            }
        }
        if full { filenameIndexKnown = false }
        for path in changedPaths where isRolloutPath(path) {
            if let id = threadID(inFilename: path) {
                discoveredPaths[id, default: []].insert(path)
            }
        }

        var retainedPaths = Set<String>()
        for id in writers.threadIDs {
            let path: String
            if let entry = registered[id] {
                // Registered-but-missing/unreadable is a genuine unknown, not an
                // unsaved context that may be excluded from the approved scope.
                guard entry.supported else { summary.unknown += 1; continue }
                path = entry.path
            } else {
                guard registeredIndexKnown else { summary.unknown += 1; continue }
                if !filenameIndexKnown { rebuildFilenameIndex() }
                let candidates = discoveredPaths[id] ?? []
                if candidates.isEmpty {
                    if filenameIndexKnown { summary.outOfScope += 1 }
                    else { summary.unknown += 1 }
                    continue
                }
                guard candidates.count == 1, let candidate = candidates.first else {
                    summary.unknown += 1
                    continue
                }
                path = candidate
            }
            retainedPaths.insert(path)
            switch updateFile(path, expectedThreadID: id) {
            case .active: summary.active += 1
            case .inactive: summary.inactive += 1
            case .unknown: summary.unknown += 1
            }
        }
        files = files.filter { retainedPaths.contains($0.key) }
        if !registeredIndexKnown { summary.inventoryComplete = false }
        lastSummary = summary
        return summary.activity
    }

    private func updateFile(_ path: String, expectedThreadID: String) -> MacCodexActivity {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  let size = attributes[.size] as? NSNumber,
                  let identity = attributes[.systemFileNumber] as? NSNumber,
                  let modified = attributes[.modificationDate] as? Date else { return .unknown }
            let cached = files[path]
            // Duplicate FSEvents/fsync notifications must not replay an unchanged
            // 100-MiB history. These attributes are cache identity, never idle evidence.
            if let cached, cached.threadID == expectedThreadID, cached.size == size.uint64Value,
               cached.identity == identity.uint64Value, cached.modified == modified {
                return cached.snapshot.activity
            }
            let previous = cached.flatMap {
                $0.threadID == expectedThreadID && $0.identity == identity.uint64Value
                    && size.uint64Value > $0.snapshot.offset ? $0.snapshot : nil
            }
            let snapshot = MacCodexRolloutLifecycle.snapshot(
                at: URL(fileURLWithPath: path), continuing: previous,
                expectedThreadID: expectedThreadID
            )
            files[path] = CachedFile(
                threadID: expectedThreadID, size: size.uint64Value, identity: identity.uint64Value,
                modified: modified, snapshot: snapshot
            )
            return snapshot.activity
        } catch {
            files.removeValue(forKey: path)
            return .unknown
        }
    }

    private func isRolloutPath(_ path: String) -> Bool {
        ["sessions", "archived_sessions"].contains {
            path.hasPrefix(codexHome.appendingPathComponent($0).path + "/") && path.hasSuffix(".jsonl")
        }
    }

    private func threadID(inFilename path: String) -> String? {
        let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        let suffix = String(name.suffix(36)).lowercased()
        return UUID(uuidString: suffix) == nil ? nil : suffix
    }

    /// This scans names only, never the contents of unrelated historical chats.
    /// It is cached and invalidated by FSEvents/full checks, not repeated every poll.
    private func rebuildFilenameIndex() {
        var found: [String: Set<String>] = [:]
        var complete = true
        for directory in ["sessions", "archived_sessions"] {
            let root = codexHome.appendingPathComponent(directory)
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: root.path)
                guard attributes[.type] as? FileAttributeType == .typeDirectory else {
                    complete = false
                    continue
                }
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
                continue
            } catch {
                complete = false
                continue
            }
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles],
                errorHandler: { _, _ in complete = false; return true }
            ) else { complete = false; continue }
            for case let url as URL in enumerator where url.pathExtension == "jsonl" {
                if let id = threadID(inFilename: url.path) {
                    found[id, default: []].insert(url.standardizedFileURL.path)
                }
            }
        }
        discoveredPaths = found
        filenameIndexKnown = complete
    }

    /// Only the ID/path/mode index is selected, never conversation content.
    private func registeredRollouts() throws -> [String: RegisteredRollout] {
        var database: OpaquePointer?
        let path = codexHome.appendingPathComponent("state_5.sqlite").path
        guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
              let database else {
            if let database { sqlite3_close(database) }
            throw CocoaError(.fileReadNoPermission)
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 100)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database, "SELECT id, rollout_path, history_mode FROM threads", -1, &statement, nil
        ) == SQLITE_OK, let statement else { throw CocoaError(.fileReadUnknown) }
        defer { sqlite3_finalize(statement) }
        var result: [String: RegisteredRollout] = [:]
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { return result }
            guard step == SQLITE_ROW else { throw CocoaError(.fileReadUnknown) }
            guard let rawID = sqlite3_column_text(statement, 0) else { continue }
            let id = String(cString: rawID).lowercased()
            let path = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
            let mode = sqlite3_column_text(statement, 2).map { String(cString: $0) } ?? ""
            result[id] = RegisteredRollout(
                path: path,
                supported: ["legacy", "paginated"].contains(mode) && isRolloutPath(path)
            )
        }
    }
}

/// Uses FSEvents so all files below sessions are observed without repeatedly
/// polling the database or launching helper processes.
private nonisolated final class MacSessionFileEvents: @unchecked Sendable {
    private final class Handler: @unchecked Sendable {
        let body: @Sendable ([String], Bool) -> Void
        init(_ body: @escaping @Sendable ([String], Bool) -> Void) { self.body = body }
    }

    private let handler: Handler
    private let lock = NSLock()
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "com.danieldev.CodexBuddy.sessionEvents", qos: .utility)

    init?(root: String, onChange: @escaping @Sendable ([String], Bool) -> Void) {
        handler = Handler(onChange)
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(handler).toOpaque(),
            retain: { pointer in
                guard let pointer else { return nil }
                return UnsafeRawPointer(Unmanaged<Handler>.fromOpaque(pointer).retain().toOpaque())
            },
            release: { pointer in
                if let pointer { Unmanaged<Handler>.fromOpaque(pointer).release() }
            },
            copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
            | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagNoDefer
        )
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            { _, context, count, paths, flags, _ in
                guard let context else { return }
                let handler = Unmanaged<Handler>.fromOpaque(context).takeUnretainedValue()
                let eventPaths = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
                var relevant: [String] = []
                var full = false
                for index in 0..<min(count, eventPaths.count) {
                    let path = eventPaths[index]
                    let flag = flags[index]
                    let dropped = kFSEventStreamEventFlagMustScanSubDirs
                        | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped
                        | kFSEventStreamEventFlagRootChanged
                    if flag & FSEventStreamEventFlags(dropped) != 0 { full = true }
                    let isSession = path.contains("/sessions/") || path.contains("/archived_sessions/")
                        || path.hasSuffix("/sessions") || path.hasSuffix("/archived_sessions")
                    let isIndex = path.hasSuffix("/state_5.sqlite") || path.hasSuffix("/state_5.sqlite-wal")
                    if isSession || isIndex {
                        let changedIdentity = kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemRenamed
                        if flag & FSEventStreamEventFlags(changedIdentity) != 0 { full = true }
                    }
                    if path.hasSuffix(".jsonl"), isSession {
                        relevant.append(path)
                    } else if isIndex {
                        relevant.append(path)
                    }
                }
                if full || !relevant.isEmpty { handler.body(relevant, full) }
            },
            &context,
            [root] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.1,
            flags
        ) else { return nil }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else { stop(); return nil }
    }

    func stop() {
        lock.lock()
        let previous = stream
        stream = nil
        lock.unlock()
        if let previous {
            FSEventStreamStop(previous)
            FSEventStreamInvalidate(previous)
            FSEventStreamRelease(previous)
        }
    }

    deinit { stop() }
}
