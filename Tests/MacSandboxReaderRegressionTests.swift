import Darwin
import Foundation

@main
struct MacSandboxReaderRegressionTests {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "codexbuddy-sandbox-tests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        print("Retained sandbox fixtures: \(root.path)")
        let marker = root.appending(path: "unexpected-cli-start")
        let executable = root.appending(path: "must-not-start.sh")
        let script = "#!/bin/sh\nprintf started > '\(marker.path)'\nexit 1\n"
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

        // This dedicated test binary has its own empty defaults domain. Simulate
        // the sandbox environment before exercising the production entry point.
        precondition(CodexFolderAccess.authorizedFolderURL == nil)
        setenv("APP_SANDBOX_CONTAINER_ID", "local-regression-fixture", 1)
        precondition(CodexFolderAccess.isSandboxed)
        let reader = LocalCodexStatusReader(executableURL: executable, allowsCachedFallback: false)
        do {
            _ = try await reader.read()
            preconditionFailure("An unauthorized sandbox read must fail")
        } catch LocalCodexStatusError.codexFolderAuthorizationRequired {
            precondition(!FileManager.default.fileExists(atPath: marker.path))
        }
        await reader.suspend()
        print("PASS: sandbox entry point requires the user-selected folder and never launches the CLI")
    }
}
