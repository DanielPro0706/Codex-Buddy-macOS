import CloudKit
import Foundation

@main
struct CloudSyncCancellationTests {
    @MainActor static func main() async throws {
        let cancellations: [any Error] = [
            CancellationError(),
            URLError(.cancelled),
            NSError(domain: NSURLErrorDomain, code: URLError.cancelled.rawValue),
            CKError(.operationCancelled),
            NSError(domain: "CancellationWrapper", code: 1, userInfo: [
                NSUnderlyingErrorKey: CKError(.operationCancelled)
            ]),
            CKError(.partialFailure, userInfo: [CKPartialErrorsByItemIDKey: [
                "first": CKError(.operationCancelled),
                "second": CKError(.operationCancelled)
            ]])
        ]
        for error in cancellations {
            try expect(CodexCloudSync.isCancellation(error), "Cancellation was not recognized: \(error)")
            try expect(CodexCloudSync.operationStatus(for: error) == .cancelled,
                       "Cancellation was reported as a failure")
        }

        let failures: [(any Error, CodexCloudSync.OperationStatus)] = [
            (CKError(.networkFailure), .failed(.network)),
            (CKError(.permissionFailure), .failed(.permission)),
            (CKError(.badContainer), .failed(.configuration)),
            (CKError(.requestRateLimited), .failed(.rateLimited)),
            (CKError(.notAuthenticated), .unavailable(.noAccount))
        ]
        for (error, expected) in failures {
            try expect(!CodexCloudSync.isCancellation(error), "A genuine error was hidden as cancellation")
            try expect(CodexCloudSync.operationStatus(for: error) == expected,
                       "An existing error classification changed")
        }
        let deniedWithUnderlyingCancellation = CKError(.permissionFailure, userInfo: [
            NSUnderlyingErrorKey: CKError(.operationCancelled)
        ])
        try expect(!CodexCloudSync.isCancellation(deniedWithUnderlyingCancellation),
                   "A real permission error was hidden by an underlying cancellation")
        try expect(CodexCloudSync.operationStatus(for: deniedWithUnderlyingCancellation) == .failed(.permission),
                   "A permission error lost its classification")
        let mixed = CKError(.partialFailure, userInfo: [CKPartialErrorsByItemIDKey: [
            "cancelled": CKError(.operationCancelled),
            "denied": CKError(.permissionFailure)
        ]])
        try expect(!CodexCloudSync.isCancellation(mixed), "Mixed partial failures must remain visible")
        if case .failed = CodexCloudSync.operationStatus(for: mixed) {} else {
            throw TestFailure(message: "Mixed partial failures were hidden")
        }
        try expect(!CodexCloudSync.OperationStatus.cancelled.isSuccessful,
                   "A cancelled operation cannot count as a successful sync")

        // Cancelling before these entry points run must throw before creating a
        // CloudKit container. No iCloud account, entitlement or network is needed.
        let account = Task { @MainActor in try await CodexCloudSync.accountAvailability() }
        account.cancel()
        do {
            _ = try await account.value
            throw TestFailure(message: "A pre-cancelled account check completed")
        } catch is CancellationError {}

        let fetch = Task { @MainActor in try await CodexCloudSync.fetch() }
        fetch.cancel()
        do {
            _ = try await fetch.value
            throw TestFailure(message: "A pre-cancelled fetch completed")
        } catch is CancellationError {}

        let publish = Task { @MainActor in
            try await CodexCloudSync.publish(snapshot: .preview, pushSecret: "test-only")
        }
        publish.cancel()
        do {
            _ = try await publish.value
            throw TestFailure(message: "A pre-cancelled publish completed")
        } catch is CancellationError {}

        print("CloudKit cancellation classification and entry-point tests passed")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw TestFailure(message: message) }
    }
    private struct TestFailure: Error { let message: String }
}
