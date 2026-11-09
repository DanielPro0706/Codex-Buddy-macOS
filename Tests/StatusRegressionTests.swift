import Foundation

@main
struct StatusRegressionTests {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "codexbuddy-tests-\(UUID())")
        let sessions = root.appending(path: "sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { print("Retained status fixtures: \(root.path)") }
        let fresh = Date(timeIntervalSince1970: 1_790_956_800)
        let old = fresh.addingTimeInterval(-3_600)
        let touched = fresh.addingTimeInterval(600)

        func write(_ name: String, date: String?, used: Int, modifiedAt: Date) throws {
            var event: [String: Any] = ["payload": ["type": "token_count", "rate_limits": ["primary": ["used_percent": used, "window_minutes": 300]]]]
            if let date { event["timestamp"] = date }
            var data = try JSONSerialization.data(withJSONObject: event)
            data.append(0x0A)
            let url = sessions.appending(path: name)
            try data.write(to: url)
            try FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: url.path)
        }
        let formatter = ISO8601DateFormatter()
        try write("old-touched.jsonl", date: formatter.string(from: old), used: 10, modifiedAt: touched)
        try write("fresh.jsonl", date: formatter.string(from: fresh), used: 80, modifiedAt: fresh.addingTimeInterval(1))
        assert(LocalCodexSessionLog.latestSnapshot(in: root)?.fiveHour?.usedPercent == 80, "file modification time must not choose stale usage")
        print("PASS: newest rate-limit timestamp wins over a recently touched old log")

        for i in 0..<12 {
            try write("noise-\(i).jsonl", date: "invalid", used: 1, modifiedAt: touched.addingTimeInterval(Double(i)))
        }
        assert(LocalCodexSessionLog.latestSnapshot(in: sessions)?.fiveHour?.usedPercent == 80, "newest valid status must be found beyond the first ten logs")
        print("PASS: no ten-file cutoff; authorized sessions folder works")

        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fraction = fresh.addingTimeInterval(0.125)
        try write("fractional.jsonl", date: formatter.string(from: fraction), used: 81, modifiedAt: touched)
        let result = LocalCodexSessionLog.latestSnapshot(in: root)!
        assert(abs(result.capturedAt.timeIntervalSince(fraction)) < 0.001)
        assert(result.fiveHour?.usedPercent == 81)
        print("PASS: fractional timestamps retain the true capture time")

        try write("missing-time.jsonl", date: nil, used: 99, modifiedAt: touched.addingTimeInterval(30))
        assert(LocalCodexSessionLog.latestSnapshot(in: root)?.fiveHour?.usedPercent == 81)
        print("PASS: malformed or missing timestamps cannot masquerade as a fresh snapshot")

        let noisyServer = root.appending(path: "noisy-server.sh")
        let script = """
        #!/bin/sh
        while IFS= read -r request; do
            case "$request" in
                *'"initialize"'*) printf '%s\\n' '{"id":1,"result":{}}' ;;
                *rateLimits*)
                    dd if=/dev/zero bs=1024 count=256 >&2
                    printf '%s\\n' '{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":42,"windowDurationMins":300}}}}'
                    ;;
            esac
        done
        """
        try Data(script.utf8).write(to: noisyServer)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: noisyServer.path)
        let start = Date.now
        let liveSnapshot = try await CodexAppServerSession(executableURL: noisyServer).readSnapshot()
        assert(liveSnapshot.source == .appServer && liveSnapshot.fiveHour?.usedPercent == 42)
        assert(Date.now.timeIntervalSince(start) < 5, "diagnostic output must not fill a pipe and block the response")
        print("PASS: 256 KiB of app-server stderr cannot block a live RPC response")

        // A Cloud worker does not have ChatGPT/Codex installed. Exercise the
        // production search against temporary copies of its candidate paths.
        let bundledPath = "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"
        assert(CodexExecutableLocator.candidates.first == bundledPath)
        let fixturePaths = CodexExecutableLocator.candidates.map {
            root.appending(path: String($0.dropFirst())).path
        }
        for index in [0, fixturePaths.count - 1] {
            let fixture = URL(filePath: fixturePaths[index])
            try FileManager.default.createDirectory(at: fixture.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: fixture)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.path)
        }
        assert(CodexExecutableLocator.firstExecutablePath(in: fixturePaths) == fixturePaths[0], "current bundled CLI must take priority over fallback installations")
        try FileManager.default.moveItem(
            atPath: fixturePaths[0],
            toPath: root.appending(path: "retained-bundled-cli").path
        )
        assert(CodexExecutableLocator.firstExecutablePath(in: fixturePaths) == fixturePaths.last, "a missing bundle must use an executable fallback")
        try FileManager.default.moveItem(
            atPath: fixturePaths.last!,
            toPath: root.appending(path: "retained-fallback-cli").path
        )
        assert(CodexExecutableLocator.firstExecutablePath(in: fixturePaths) == nil, "a worker without Codex must report absence without requiring an installation")
        print("PASS: bundled CLI priority, executable fallback and absence use temporary fixtures")
    }
}
