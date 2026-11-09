import Foundation
import SQLite3

private nonisolated final class WriterInventoryFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var value = MacCodexWriterInventory(threadIDs: [], isComplete: true, runtimeCount: 0)

    func read() -> MacCodexWriterInventory {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ newValue: MacCodexWriterInventory) {
        lock.lock()
        value = newValue
        lock.unlock()
    }
}

@main
struct MacRefreshEnvironmentTests {
    static func main() async throws {
        let beginning = Date(timeIntervalSince1970: 1_000_000)
        let idle = MacRefreshEnvironment(allDisplaysAsleep: true, activity: .inactive)
        let awake = MacRefreshEnvironment(allDisplaysAsleep: false, activity: .inactive)
        let working = MacRefreshEnvironment(allDisplaysAsleep: true, activity: .active)
        let uncertain = MacRefreshEnvironment(allDisplaysAsleep: true, activity: .unknown)
        var policy = MacRefreshPolicy(environment: idle, now: beginning)
        assert(policy.interval == .seconds(1_800))
        policy.update(environment: idle, now: beginning.addingTimeInterval(600))
        assert(policy.nextDelay(now: beginning.addingTimeInterval(600)) == .seconds(1_200))
        policy.didPerformScheduledCheck(environment: idle, now: beginning.addingTimeInterval(1_799))
        assert(policy.phase == .initialIdle)
        policy.didPerformScheduledCheck(environment: idle, now: beginning.addingTimeInterval(1_800))
        assert(policy.interval == .seconds(3_600))
        print("PASS: idle starts with 30 minutes; repeated observations preserve the deadline; only a due check promotes to 60 minutes")

        for resumed in [awake, working, uncertain] {
            var state = policy
            state.update(environment: resumed, now: beginning.addingTimeInterval(1_801))
            assert(state.interval == .seconds(15))
            state.update(environment: idle, now: beginning.addingTimeInterval(1_802))
            assert(state.interval == .seconds(1_800))
            state.didPerformScheduledCheck(environment: working, now: beginning.addingTimeInterval(9_000))
            assert(state.interval == .seconds(15))
        }
        var manual = MacRefreshPolicy(environment: idle, now: beginning)
        manual.update(environment: idle, now: beginning.addingTimeInterval(7_200))
        assert(manual.phase == .initialIdle)
        assert(manual.nextDelay(now: beginning.addingTimeInterval(-7_200)) == .seconds(1_800))
        print("PASS: ordinary awake state, an active turn, and unknown activity reset backoff; manual observations do not confirm idle")

        var battery = awake
        battery.isOnACPower = false
        assert(MacRefreshPolicy(environment: battery, now: beginning).interval == .seconds(30))
        var powerUnknown = awake
        powerUnknown.isPowerSourceKnown = false
        assert(MacRefreshPolicy(environment: powerUnknown, now: beginning).interval == .seconds(30))
        var closedWithExternal = awake
        closedWithExternal.lidClosed = true
        closedWithExternal.hasExternalDisplay = true
        assert(!closedWithExternal.isIdleEligible)
        for signal in ["lock", "saver", "sleep", "no-external"] {
            var environment = closedWithExternal
            switch signal {
            case "lock": environment.isScreenLocked = true
            case "saver": environment.isScreenSaverRunning = true
            case "sleep": environment.allExternalDisplaysAsleep = true
            default: environment.hasExternalDisplay = false
            }
            assert(MacRefreshPolicy(environment: environment, now: beginning).interval == .seconds(1_800))
            environment.activity = .active
            assert(MacRefreshPolicy(environment: environment, now: beginning).interval == .seconds(15))
            environment.isOnACPower = false
            assert(MacRefreshPolicy(environment: environment, now: beginning).interval == .seconds(30))
        }
        var openLocked = awake
        openLocked.isScreenLocked = true
        assert(!openLocked.isIdleEligible)
        openLocked.isScreenSaverRunning = true
        assert(!openLocked.isIdleEligible)
        var stillIdleOnBattery = policy.environment
        stillIdleOnBattery.isOnACPower = false
        let beforePowerChange = policy.phase
        policy.update(environment: stillIdleOnBattery, now: beginning.addingTimeInterval(1_801))
        assert(policy.phase == beforePowerChange && policy.interval == .seconds(3_600))
        print("PASS: AC uses 15s, battery/unknown power use 30s; closed-lid external lock/saver/sleep and no-external cases back off, and active work overrides every idle signal")

        let fixtures = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexBuddyRefreshEnvironmentTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: fixtures, withIntermediateDirectories: true)
        func write(_ name: String, _ data: Data) throws -> URL {
            let url = fixtures.appendingPathComponent(name)
            try data.write(to: url)
            return url
        }
        func event(_ type: String, _ turn: String = "turn-a") -> String {
            "{\"type\":\"event_msg\",\"payload\":{\"type\":\"\(type)\",\"turn_id\":\"\(turn)\"}}\n"
        }
        func expect(_ name: String, _ data: Data, _ expected: MacCodexActivity) throws {
            let url = try write(name, data)
            assert(MacCodexRolloutLifecycle.activity(at: url) == expected, name)
        }
        let start = event("task_started")
        let complete = event("task_complete")
        let aborted = event("turn_aborted")
        try expect("active.jsonl", Data(start.utf8), .active)
        try expect("complete.jsonl", Data((start + complete).utf8), .inactive)
        try expect("aborted.jsonl", Data((start + aborted).utf8), .inactive)
        let restarted = start + complete + event("task_started", "turn-b")
        try expect("restarted.jsonl", Data(restarted.utf8), .active)
        assert(MacCodexRolloutLifecycle.activity(at: fixtures.appendingPathComponent("missing.jsonl")) == .unknown)
        try expect("empty.jsonl", Data(), .unknown)
        let malformed = complete + "{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_started\",oops}}\n"
        try expect("malformed.jsonl", Data(malformed.utf8), .unknown)
        let invalidSkippedValue = start + complete + "{\"type\":\"response_item\",\"unused\":\"bad\\q\"}\n"
        try expect("invalid-unused-value.jsonl", Data(invalidSkippedValue.utf8), .unknown)
        let missingTurn = complete + "{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_started\"}}\n"
        try expect("missing-turn.jsonl", Data(missingTurn.utf8), .unknown)
        try expect("partial.jsonl", Data((complete + "{\"type\":").utf8), .unknown)
        // Strings in a message must never be mistaken for lifecycle events.
        let quoted = "{\"type\":\"response_item\",\"payload\":{\"type\":\"task_started\",\"turn_id\":\"not-a-lifecycle\"}}\n"
        try expect("quoted.jsonl", Data((start + complete + quoted).utf8), .inactive)
        try expect("orphan-terminal.jsonl", Data(complete.utf8), .unknown)
        let overlap = start + event("task_started", "turn-b") + event("task_complete", "turn-b")
        try expect("overlap.jsonl", Data(overlap.utf8), .active)
        try expect("overlap-complete.jsonl", Data((overlap + complete).utf8), .inactive)
        try expect("wrong-terminal.jsonl", Data((start + event("task_complete", "unrelated")).utf8), .unknown)
        print("PASS: complete, aborted, and restarted turn states are distinguished; malformed, partial, empty, and unreadable evidence stays unknown")

        let largeMessage = "{\"type\":\"response_item\",\"payload\":{\"padding\":\"" + String(repeating: "x", count: 700_000) + "\"}}\n"
        let longActive = try write("long-active.jsonl", Data((start + largeMessage).utf8))
        assert(MacCodexRolloutLifecycle.activity(at: longActive) == .active)
        assert(MacCodexRolloutLifecycle.activity(at: longActive, maximumScanBytes: 64 * 1024) == .unknown)
        let largeValidLine = "{\"type\":\"response_item\",\"payload\":{\"padding\":\""
            + String(repeating: "x", count: 9 * 1024 * 1024) + "\"}}\n"
        let largeSaved = try write("large-saved.jsonl", Data((start + largeValidLine + complete).utf8))
        assert(MacCodexRolloutLifecycle.activity(at: largeSaved) == .inactive)
        print("PASS: an active start outside the usual log tail is found; exceeding the explicit scan bound never becomes inactive")

        let incremental = try write("incremental.jsonl", Data(start.utf8))
        let first = MacCodexRolloutLifecycle.snapshot(at: incremental)
        assert(first.activity == .active)
        let handle = try FileHandle(forWritingTo: incremental)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(complete.utf8))
        let second = MacCodexRolloutLifecycle.snapshot(at: incremental, continuing: first)
        assert(second.activity == .inactive)
        let newStart = event("task_started", "turn-c")
        try handle.write(contentsOf: Data(newStart.dropLast().utf8))
        let partial = MacCodexRolloutLifecycle.snapshot(at: incremental, continuing: second)
        assert(partial.activity == .unknown)
        try handle.write(contentsOf: Data([0x0A]))
        let resumed = MacCodexRolloutLifecycle.snapshot(at: incremental, continuing: partial)
        assert(resumed.activity == .active)
        try handle.close()
        print("PASS: overlapping turns require matching completion; incremental reads preserve active state and retain partial lines safely")

        let forkID = UUID().uuidString.lowercased()
        let parentID = UUID().uuidString.lowercased()
        let forkMetadata = "{\"ordinal\":0,\"type\":\"session_meta\",\"payload\":{\"id\":\"\(forkID)\",\"forked_from_id\":\"\(parentID)\",\"subagent_history_start_ordinal\":4}}\n"
        let inheritedMetadata = "{\"ordinal\":1,\"type\":\"session_meta\",\"payload\":{\"id\":\"\(parentID)\"}}\n"
        let inheritedStart = "{\"ordinal\":2,\"type\":\"event_msg\",\"payload\":{\"type\":\"task_started\",\"turn_id\":\"parent-turn\"}}\n"
        let inheritedContext = "{\"ordinal\":3,\"type\":\"response_item\",\"payload\":{\"type\":\"message\"}}\n"
        let forkPrefix = forkMetadata + inheritedMetadata + inheritedStart + inheritedContext
        let forkFile = try write("fork-context.jsonl", Data(forkPrefix.utf8))
        assert(MacCodexRolloutLifecycle.activity(at: forkFile, expectedThreadID: forkID) == .inactive)
        let incompleteFork = try write("fork-incomplete.jsonl", Data((forkMetadata + inheritedMetadata + inheritedStart).utf8))
        assert(MacCodexRolloutLifecycle.activity(at: incompleteFork, expectedThreadID: forkID) == .unknown)
        let ownStart = "{\"ordinal\":4,\"type\":\"event_msg\",\"payload\":{\"type\":\"task_started\",\"turn_id\":\"child-turn\"}}\n"
        let ownComplete = "{\"ordinal\":5,\"type\":\"event_msg\",\"payload\":{\"type\":\"task_complete\",\"turn_id\":\"child-turn\"}}\n"
        let forkActive = try write("fork-active.jsonl", Data((forkPrefix + ownStart).utf8))
        let forkComplete = try write("fork-complete.jsonl", Data((forkPrefix + ownStart + ownComplete).utf8))
        assert(MacCodexRolloutLifecycle.activity(at: forkActive, expectedThreadID: forkID) == .active)
        assert(MacCodexRolloutLifecycle.activity(at: forkComplete, expectedThreadID: forkID) == .inactive)
        assert(MacCodexRolloutLifecycle.activity(at: forkComplete, expectedThreadID: UUID().uuidString) == .unknown)
        let missingOrdinal = try write("fork-missing-ordinal.jsonl", Data((forkMetadata + inheritedMetadata + start).utf8))
        assert(MacCodexRolloutLifecycle.activity(at: missingOrdinal, expectedThreadID: forkID) == .unknown)
        print("PASS: explicit fork ordinals exclude inherited parent turns and metadata; incomplete prefixes, missing ordinals, and wrong identities remain unknown")

        let home = fixtures.appendingPathComponent("codex-home")
        let sessions = home.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let id = UUID().uuidString.lowercased()
        let session = sessions.appendingPathComponent("rollout-" + id + ".jsonl")
        try Data(start.utf8).write(to: session)
        var database: OpaquePointer?
        assert(sqlite3_open(home.appendingPathComponent("state_5.sqlite").path, &database) == SQLITE_OK)
        func sql(_ statement: String) {
            assert(sqlite3_exec(database, statement, nil, nil, nil) == SQLITE_OK)
        }
        func sqlQuoted(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "''") + "'" }
        sql("CREATE TABLE threads (id TEXT, rollout_path TEXT, history_mode TEXT, archived INTEGER)")
        // Archived is not an inactivity signal: an archived descendant can resume.
        sql("INSERT INTO threads VALUES (\(sqlQuoted(id)),\(sqlQuoted(session.path)),'paginated',1)")
        sql("INSERT INTO threads VALUES ('old-unloaded','/missing/old.jsonl','paginated',0)")
        let inventory = WriterInventoryFixture()
        let index = MacCodexActivityIndex(codexHome: home, inventory: { _ in inventory.read() })
        let unloaded = await index.scan(changedPaths: [], full: true)
        assert(unloaded == .inactive)
        inventory.set(.init(threadIDs: [id], isComplete: true, runtimeCount: 1))
        let archivedActive = await index.scan(changedPaths: [], full: true)
        assert(archivedActive == .active)
        let append = try FileHandle(forWritingTo: session)
        try append.seekToEnd()
        try append.write(contentsOf: Data(complete.utf8))
        try append.close()
        let finished = await index.scan(changedPaths: [session.path], full: false)
        assert(finished == .inactive)
        inventory.set(.init(threadIDs: [], isComplete: false, runtimeCount: 1))
        let permissionFailure = await index.scan(changedPaths: [], full: false)
        assert(permissionFailure == .unknown)
        inventory.set(.init(threadIDs: [UUID().uuidString.lowercased()], isComplete: true, runtimeCount: 1))
        let unindexedWriter = await index.scan(changedPaths: [], full: false)
        let unsavedSummary = await index.lastSummary
        assert(unindexedWriter == .inactive && unsavedSummary.outOfScope == 1 && unsavedSummary.inactive == 0)
        let savedWithoutIndex = UUID().uuidString.lowercased()
        let savedFile = sessions.appendingPathComponent("rollout-" + savedWithoutIndex + ".jsonl")
        let metadata = "{\"type\":\"session_meta\",\"payload\":{\"id\":\"\(savedWithoutIndex)\"}}\n"
        let context = "{\"type\":\"response_item\",\"payload\":{\"type\":\"message\"}}\n"
        try Data((metadata + context).utf8).write(to: savedFile)
        inventory.set(.init(threadIDs: [savedWithoutIndex], isComplete: true, runtimeCount: 1))
        let contextOnly = await index.scan(changedPaths: [savedFile.path], full: true)
        assert(contextOnly == .inactive)
        let contextSummary = await index.lastSummary
        assert(contextSummary.inactive == 1 && contextSummary.outOfScope == 0)
        let contextHandle = try FileHandle(forWritingTo: savedFile)
        try contextHandle.seekToEnd()
        try contextHandle.write(contentsOf: Data(event("task_started", "new-turn").utf8))
        try contextHandle.close()
        let unindexedActive = await index.scan(changedPaths: [savedFile.path], full: false)
        assert(unindexedActive == .active)
        let missingID = UUID().uuidString.lowercased()
        sql("INSERT INTO threads VALUES (\(sqlQuoted(missingID)),'\(sessions.path)/missing.jsonl','paginated',0)")
        inventory.set(.init(threadIDs: [missingID], isComplete: true, runtimeCount: 1))
        let registeredMissing = await index.scan(changedPaths: [], full: true)
        assert(registeredMissing == .unknown)
        sqlite3_close(database)
        print("PASS: stale unloaded history is ignored, archived live writers remain active, unregistered saved files are observed, unsaved contexts are explicitly out of scope, and registered missing files remain unknown")
        print("Retained test fixtures: \(fixtures.path)")
    }
}
