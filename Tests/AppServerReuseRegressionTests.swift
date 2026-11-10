import Darwin
import Foundation

private struct RegressionFailure: Error, CustomStringConvertible {
    let description: String
}

private func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw RegressionFailure(description: message) }
}

private struct ServerFixture {
    let root: URL
    let executable: URL

    init(parent: URL, name: String, mode: String, source: URL) throws {
        root = parent.appending(path: name)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        executable = root.appending(path: "app-server-fixture.sh")
        let quote: (String) -> String = { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let script = """
        #!/bin/sh
        export CODEX_BUDDY_FIXTURE_ROOT=\(quote(root.path))
        export CODEX_BUDDY_FIXTURE_MODE=\(quote(mode))
        exec /usr/bin/env python3 \(quote(source.path)) "$@"
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    }

    func events() -> [[String: Any]] {
        guard let data = try? Data(contentsOf: root.appending(path: "events.jsonl")),
              let text = String(data: data, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap {
            guard let line = $0.data(using: .utf8) else { return nil }
            return try? JSONSerialization.jsonObject(with: line) as? [String: Any]
        }
    }

    func requests(_ method: String) -> [[String: Any]] {
        events().filter { $0["event"] as? String == "request" && $0["method"] as? String == method }
    }

    func waitForStartup() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        repeat {
            if events().contains(where: { $0["event"] as? String == "spawn" }) { return }
            try await Task.sleep(for: .milliseconds(10))
        } while ContinuousClock.now < deadline
        throw RegressionFailure(description: "local fixture did not finish starting within its startup budget")
    }

    func assertExited() async throws {
        let pids = Set(events().filter { $0["event"] as? String == "spawn" }.compactMap { $0["pid"] as? Int32 })
        guard !pids.isEmpty else {
            throw RegressionFailure(description: "fixture never recorded its child PID")
        }
        for pid in pids {
            var exited = false
            for _ in 0..<100 {
                if kill(pid, 0) == -1 && errno == ESRCH { exited = true; break }
                try await Task.sleep(for: .milliseconds(20))
            }
            try check(exited, "stopped fixture child \(pid) is still alive")
        }
    }
}

private func residentBytes() throws -> UInt64 {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    guard result == KERN_SUCCESS else {
        throw RegressionFailure(description: "could not read this test process's resident memory")
    }
    return UInt64(info.resident_size)
}

private final class AdvancingClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = ContinuousClock.now

    func now() -> ContinuousClock.Instant {
        lock.withLock { instant }
    }

    func advance(by duration: Duration) {
        lock.withLock { instant = instant.advanced(by: duration) }
    }
}

@main
struct AppServerReuseRegressionTests {
    static func main() async throws {
        let fixtureSource = CommandLine.arguments.dropFirst().first.map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/app_server_fixture.py")
        try check(FileManager.default.fileExists(atPath: fixtureSource.path), "missing local fixture: \(fixtureSource.path)")
        let root = FileManager.default.temporaryDirectory.appending(path: "codexbuddy-app-server-tests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Retain diagnostic fixtures; no test permanently deletes user or temporary files.
        print("Retained local fixtures: \(root.path)")

        try await testReuse(root: root, source: fixtureSource)
        try await testConcurrentSession(root: root, source: fixtureSource)
        try await testIdleNotifications(root: root, source: fixtureSource)
        try await testStderr(root: root, source: fixtureSource)
        for mode in ["eof-initialize", "eof-read"] {
            try await testFailure(root: root, source: fixtureSource, mode: mode, expected: .serviceEnded)
        }
        for mode in ["hang-initialize", "hang-read"] {
            try await testFailure(root: root, source: fixtureSource, mode: mode, expected: .timeout)
        }
        try await testStopPendingRequest(root: root, source: fixtureSource)
        try await testReaderReuseAndSuspend(root: root, source: fixtureSource)
        try await testReaderSingleFlight(root: root, source: fixtureSource)
        try await testReaderOneShot(root: root, source: fixtureSource)
        try await testReaderReconnect(root: root, source: fixtureSource)
        try await testReaderSuspendInFlight(root: root, source: fixtureSource)
        try await testReaderRebuildBackoff(root: root, source: fixtureSource)
        print("PASS: all persistent app-server regressions use local fixtures only")
    }

    private static func testReuse(root: URL, source: URL) async throws {
        let fixture = try ServerFixture(parent: root, name: "reuse", mode: "healthy", source: source)
        let session = try CodexAppServerSession(executableURL: fixture.executable)
        do {
            for expected in [11, 12, 13] {
                let snapshot = try await session.readSnapshot()
                try check(snapshot.source == .appServer && snapshot.fiveHour?.usedPercent == expected,
                          "reused connection must return each fresh response, not a prior cached reply")
            }
            try check(fixture.requests("initialize").count == 1, "three reads must initialize exactly one app-server")
            try check(fixture.requests("initialized").count == 1, "initialized notification must be sent once per session")
            let ids = fixture.requests("account/rateLimits/read").compactMap { $0["id"] as? Int }
            try check(ids.count == 3 && Set(ids).count == 3, "reused requests must have distinct RPC IDs")
            session.stop()
            session.stop()
            do {
                _ = try await session.readSnapshot()
                throw RegressionFailure(description: "an explicitly stopped session must not restart itself")
            } catch let error as LocalCodexStatusError {
                try check(isSameCase(error, .serviceEnded), "read after stop must fail as serviceEnded")
            }
            try await fixture.assertExited()
            print("PASS: three reads reuse one initialization, receive fresh replies, and stop is terminal")
        } catch {
            session.stop()
            throw error
        }
    }

    private static func testConcurrentSession(root: URL, source: URL) async throws {
        let fixture = try ServerFixture(parent: root, name: "concurrent-session", mode: "delayed-initialize", source: source)
        let session = try CodexAppServerSession(executableURL: fixture.executable)
        do {
            let values = try await withThrowingTaskGroup(of: Int.self) { group in
                for _ in 0..<6 {
                    group.addTask {
                        let snapshot = try await session.readSnapshot()
                        return snapshot.fiveHour?.usedPercent ?? -1
                    }
                }
                var values: [Int] = []
                for try await value in group { values.append(value) }
                return values
            }
            try check(Set(values) == Set(11...16), "concurrent RPCs must receive distinct matching responses")
            try check(fixture.requests("initialize").count == 1, "concurrent first reads must share one initialization")
            try check(fixture.requests("initialized").count == 1, "concurrent initialization must emit one initialized notification")
            let ids = fixture.requests("account/rateLimits/read").compactMap { $0["id"] as? Int }
            try check(ids.count == 6 && Set(ids).count == 6, "concurrent requests must preserve unique IDs")
            session.stop()
            try await fixture.assertExited()
            print("PASS: concurrent session reads initialize once and route responses by RPC ID")
        } catch {
            session.stop()
            throw error
        }
    }

    private static func testIdleNotifications(root: URL, source: URL) async throws {
        let fixture = try ServerFixture(parent: root, name: "idle-notifications", mode: "idle-notifications", source: source)
        let session = try CodexAppServerSession(executableURL: fixture.executable)
        do {
            _ = try await session.readSnapshot()
            let before = try residentBytes()
            try Data().write(to: fixture.root.appending(path: "start-flood"))
            var finished = false
            for _ in 0..<1_000 {
                if fixture.events().contains(where: { $0["event"] as? String == "idleFloodFinished" }) {
                    finished = true
                    break
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            try check(finished, "idle notification flood must drain without waiting for the next quota read")
            try await Task.sleep(for: .milliseconds(100))
            let after = try residentBytes()
            let growth = after > before ? after - before : 0
            try check(growth < 32 * 1024 * 1024,
                      "64 MiB of idle notifications must not accumulate indefinitely (resident growth: \(growth) bytes)")
            let snapshot = try await session.readSnapshot()
            try check(snapshot.fiveHour?.usedPercent == 12, "notifications and unrelated response IDs must not consume quota responses")
            try check(fixture.requests("initialize").count == 1, "notification load must not trigger reinitialization")
            session.stop()
            try await fixture.assertExited()
            print("PASS: idle notifications drain with bounded memory and do not block a subsequent RPC")
        } catch {
            session.stop()
            throw error
        }
    }

    private static func testStderr(root: URL, source: URL) async throws {
        let fixture = try ServerFixture(parent: root, name: "stderr", mode: "noisy-stderr", source: source)
        let session = try CodexAppServerSession(executableURL: fixture.executable, requestTimeout: .seconds(2))
        do {
            let snapshot = try await session.readSnapshot()
            try check(snapshot.fiveHour?.usedPercent == 11, "256 KiB of stderr must not fill an unread pipe")
            session.stop()
            try await fixture.assertExited()
            print("PASS: app-server diagnostic output cannot block a live response")
        } catch {
            session.stop()
            throw error
        }
    }

    private static func testFailure(root: URL, source: URL, mode: String, expected: LocalCodexStatusError) async throws {
        let fixture = try ServerFixture(parent: root, name: mode, mode: mode, source: source)
        // Process startup is not the RPC behavior under test. Wait for Python to
        // enter its input loop before starting a short intentional hang deadline.
        // EOF detection keeps its separate three-second promptness assertion.
        let timeout: Duration = isSameCase(expected, .timeout) ? .milliseconds(500) : .seconds(5)
        let session = try CodexAppServerSession(executableURL: fixture.executable, requestTimeout: timeout)
        defer { session.stop() }
        try await fixture.waitForStartup()
        let start = ContinuousClock.now
        do {
            _ = try await session.readSnapshot()
            session.stop()
            throw RegressionFailure(description: "\(mode) unexpectedly returned a snapshot")
        } catch let error as LocalCodexStatusError {
            try check(isSameCase(error, expected), "\(mode) returned the wrong failure: \(error)")
        } catch {
            session.stop()
            throw error
        }
        session.stop()
        try check(start.duration(to: .now) < .seconds(3), "\(mode) must fail promptly and remain closable")
        try await fixture.assertExited()
        print("PASS: \(mode) fails explicitly and its subprocess can be closed")
    }

    private static func testStopPendingRequest(root: URL, source: URL) async throws {
        let fixture = try ServerFixture(parent: root, name: "stop-pending", mode: "hang-read", source: source)
        let session = try CodexAppServerSession(executableURL: fixture.executable, requestTimeout: .seconds(2))
        let pending = Task { try await session.readSnapshot() }
        do {
            for _ in 0..<100 {
                if fixture.requests("account/rateLimits/read").count == 1 { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            try check(fixture.requests("account/rateLimits/read").count == 1, "fixture never received the pending read")
            let start = ContinuousClock.now
            session.stop()
            do {
                _ = try await pending.value
                throw RegressionFailure(description: "stopping a pending request must not return a snapshot")
            } catch let error as LocalCodexStatusError {
                try check(isSameCase(error, .serviceEnded), "stop must end an outstanding request as serviceEnded")
            }
            try check(start.duration(to: .now) < .seconds(1), "stop must unblock pending RPCs without waiting for their deadline")
            try await fixture.assertExited()
            print("PASS: stopping a session promptly fails outstanding RPCs and closes its child")
        } catch {
            session.stop()
            pending.cancel()
            throw error
        }
    }

    private static func testReaderReuseAndSuspend(root: URL, source: URL) async throws {
        let fixture = try ServerFixture(parent: root, name: "reader-reuse", mode: "healthy", source: source)
        let reader = LocalCodexStatusReader(executableURL: fixture.executable, requestTimeout: .seconds(2), allowsCachedFallback: false)
        do {
            for expected in [11, 12, 13] {
                let snapshot = try await reader.read()
                try check(snapshot.fiveHour?.usedPercent == expected, "reader must retain one live app-server across refreshes")
            }
            try check(fixture.requests("initialize").count == 1, "reader refreshes must not create new initialized sessions")
            await reader.suspend()
            try await fixture.assertExited()
            let afterSuspend = try await reader.read()
            try check(afterSuspend.fiveHour?.usedPercent == 11, "a suspended reader must rebuild a fresh child on its next read")
            try check(fixture.requests("initialize").count == 2, "reader must initialize exactly once after explicit suspension")
            await reader.suspend()
            try await fixture.assertExited()
            print("PASS: reader reuses its subprocess and explicitly rebuilds after suspension")
        } catch {
            await reader.suspend()
            throw error
        }
    }

    private static func testReaderSingleFlight(root: URL, source: URL) async throws {
        let fixture = try ServerFixture(parent: root, name: "reader-single-flight", mode: "delayed-read", source: source)
        let reader = LocalCodexStatusReader(executableURL: fixture.executable, requestTimeout: .seconds(2), allowsCachedFallback: false)
        do {
            let values = try await withThrowingTaskGroup(of: Int.self) { group in
                for _ in 0..<6 {
                    group.addTask { try await reader.read().fiveHour?.usedPercent ?? -1 }
                }
                var values: [Int] = []
                for try await value in group { values.append(value) }
                return values
            }
            try check(values.count == 6 && values.allSatisfy { $0 == 11 }, "overlapping reader refreshes must share one snapshot")
            try check(fixture.requests("initialize").count == 1 && fixture.requests("account/rateLimits/read").count == 1,
                      "overlapping reader refreshes must initialize and request quota only once")
            await reader.suspend()
            try await fixture.assertExited()
            print("PASS: concurrent reader refreshes share one in-flight quota request")
        } catch {
            await reader.suspend()
            throw error
        }
    }

    private static func testReaderOneShot(root: URL, source: URL) async throws {
        let fixture = try ServerFixture(parent: root, name: "reader-one-shot", mode: "healthy", source: source)
        let reader = LocalCodexStatusReader(executableURL: fixture.executable, requestTimeout: .seconds(2), allowsCachedFallback: false)
        do {
            for _ in 0..<2 {
                let snapshot = try await reader.read(keepingSessionAlive: false)
                try check(snapshot.fiveHour?.usedPercent == 11, "one-shot reads must start fresh child sessions")
                try await fixture.assertExited()
            }
            try check(fixture.requests("initialize").count == 2, "one-shot policy must release each app-server after reading")
            await reader.suspend()
            print("PASS: explicit one-shot reads release their subprocess after each refresh")
        } catch {
            await reader.suspend()
            throw error
        }
    }

    private static func testReaderReconnect(root: URL, source: URL) async throws {
        let fixture = try ServerFixture(parent: root, name: "reader-reconnect", mode: "healthy", source: source)
        let reader = LocalCodexStatusReader(executableURL: fixture.executable, requestTimeout: .seconds(2), allowsCachedFallback: false)
        do {
            let first = try await reader.read()
            try check(first.fiveHour?.usedPercent == 11, "first fixture snapshot was not returned")
            guard let pid = fixture.events().first(where: { $0["event"] as? String == "spawn" })?["pid"] as? Int32 else {
                throw RegressionFailure(description: "missing fixture PID before simulated EOF")
            }
            try check(kill(pid, SIGTERM) == 0, "could not end the local fixture child")
            try await fixture.assertExited()
            do {
                _ = try await reader.read()
                throw RegressionFailure(description: "a dead retained session must report failure before rebuilding")
            } catch let error as LocalCodexStatusError {
                try check(isSameCase(error, .serviceEnded), "a retained child EOF must surface as serviceEnded")
            }
            let recovered = try await reader.read()
            try check(recovered.fiveHour?.usedPercent == 11, "reader must rebuild after discarding its failed session")
            try check(fixture.requests("initialize").count == 2, "recovery must initialize exactly one replacement session")
            await reader.suspend()
            try await fixture.assertExited()
            print("PASS: reader discards an ended session and reconnects on the following read")
        } catch {
            await reader.suspend()
            throw error
        }
    }

    private static func testReaderSuspendInFlight(root: URL, source: URL) async throws {
        let fixture = try ServerFixture(parent: root, name: "reader-suspend-in-flight", mode: "delayed-read", source: source)
        let reader = LocalCodexStatusReader(executableURL: fixture.executable, requestTimeout: .seconds(2), allowsCachedFallback: false)
        let pending = Task { try await reader.read() }
        do {
            for _ in 0..<100 {
                if fixture.requests("account/rateLimits/read").count == 1 { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            try check(fixture.requests("account/rateLimits/read").count == 1, "reader fixture never received its pending RPC")
            await reader.suspend()
            try await fixture.assertExited()
            try await Task.sleep(for: .milliseconds(100))
            try check(fixture.events().filter { $0["event"] as? String == "spawn" }.count == 1,
                      "a canceled in-flight refresh must not start another subprocess while suspended")
            let restarted = try await reader.read()
            try check(restarted.fiveHour?.usedPercent == 11, "read after an in-flight suspension must use a replacement child")
            do {
                _ = try await pending.value
                throw RegressionFailure(description: "suspension must end the old in-flight refresh")
            } catch is CancellationError {
                // Either cancellation or EOF is an explicit end of the old request.
            } catch let error as LocalCodexStatusError {
                try check(isSameCase(error, .serviceEnded), "suspended in-flight request returned an unexpected error")
            }
            let next = try await reader.read()
            try check(next.fiveHour?.usedPercent == 12, "completion of the old task must not discard the new live session")
            try check(fixture.requests("initialize").count == 2, "suspension must rebuild once and retain the replacement")
            await reader.suspend()
            try await fixture.assertExited()
            print("PASS: suspending an in-flight refresh cancels it without discarding the replacement session")
        } catch {
            await reader.suspend()
            pending.cancel()
            throw error
        }
    }

    private static func testReaderRebuildBackoff(root: URL, source: URL) async throws {
        let fixture = try ServerFixture(parent: root, name: "reader-rebuild-backoff", mode: "controlled-read-error", source: source)
        let clock = AdvancingClock()
        let reader = LocalCodexStatusReader(
            executableURL: fixture.executable,
            requestTimeout: .seconds(2),
            allowsCachedFallback: false,
            now: { clock.now() }
        )
        let initializationCount = { fixture.requests("initialize").count }
        func expectFailure() async throws {
            do {
                _ = try await reader.read()
                throw RegressionFailure(description: "controlled failing RPC unexpectedly succeeded")
            } catch let error as LocalCodexStatusError {
                try check(isSameCase(error, .invalidResponse), "cooldown must preserve the actual live-read error")
            }
        }
        do {
            let failures = await withTaskGroup(of: Bool.self) { group in
                for _ in 0..<6 {
                    group.addTask {
                        do {
                            _ = try await reader.read()
                            return false
                        } catch let error as LocalCodexStatusError {
                            return isSameCase(error, .invalidResponse)
                        } catch {
                            return false
                        }
                    }
                }
                var result: [Bool] = []
                for await value in group { result.append(value) }
                return result
            }
            try check(failures.count == 6 && failures.allSatisfy { $0 }, "concurrent failing refreshes must share the explicit RPC error")
            try check(initializationCount() == 1, "one shared failed refresh must count as one startup failure")
            try await expectFailure()
            try check(initializationCount() == 2, "the first failure must allow the following read to reconnect immediately")
            await reader.suspend()
            for _ in 0..<6 { try await expectFailure() }
            try check(initializationCount() == 2, "cooldown reads and suspension must not restart the CLI or advance failure counts")

            var expectedStarts = 2
            for seconds in [30, 60, 120, 240, 300, 300] {
                clock.advance(by: .seconds(seconds - 1))
                try await expectFailure()
                try check(initializationCount() == expectedStarts, "retry occurred before the \(seconds)-second cooldown expired")
                clock.advance(by: .seconds(1))
                try await expectFailure()
                expectedStarts += 1
                try check(initializationCount() == expectedStarts, "cooldown boundary must allow exactly one replacement CLI")
            }

            let success = try JSONSerialization.data(withJSONObject: ["success": true])
            try success.write(to: fixture.root.appending(path: "control.json"))
            clock.advance(by: .seconds(300))
            let recovered = try await reader.read()
            expectedStarts += 1
            try check(recovered.fiveHour?.usedPercent == 11 && initializationCount() == expectedStarts,
                      "a successful live retry must return a real fresh snapshot")
            let next = try await reader.read()
            try check(next.fiveHour?.usedPercent == 12 && initializationCount() == expectedStarts,
                      "a recovered reader must keep reusing its live child")

            let failure = try JSONSerialization.data(withJSONObject: ["success": false])
            try failure.write(to: fixture.root.appending(path: "control.json"))
            try await expectFailure()
            try await expectFailure()
            expectedStarts += 1
            try check(initializationCount() == expectedStarts,
                      "live success must reset failures so the next single failure permits immediate reconnect")
            try await expectFailure()
            try check(initializationCount() == expectedStarts, "a new pair of failures must enter cooldown again")
            await reader.suspend()
            try await fixture.assertExited()
            print("PASS: shared failures back off CLI rebuilds at 30/60/120/240/300 seconds and live recovery resets them")
        } catch {
            await reader.suspend()
            throw error
        }
    }

    private static func isSameCase(_ lhs: LocalCodexStatusError, _ rhs: LocalCodexStatusError) -> Bool {
        switch (lhs, rhs) {
        case (.serviceEnded, .serviceEnded), (.timeout, .timeout), (.invalidResponse, .invalidResponse): true
        default: false
        }
    }
}
