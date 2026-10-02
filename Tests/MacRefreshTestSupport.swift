import AppKit
import Foundation
import Network

@MainActor enum RefreshTestState {
    static var next = CodexStatusSnapshot.preview
    static var saved: CodexStatusSnapshot?
    static var reads = 0
    static var published: [CodexStatusSnapshot] = []
    static var cloudContinuations: [CheckedContinuation<Void, Never>] = []
}
actor LocalCodexStatusReader {
    func read() async throws -> CodexStatusSnapshot {
        await MainActor.run {
            RefreshTestState.reads += 1
            return RefreshTestState.next
        }
    }
}
enum CodexStatusCache {
    static func loadSnapshot() -> CodexStatusSnapshot? { RefreshTestState.saved }
    static func save(snapshot: CodexStatusSnapshot) { RefreshTestState.saved = snapshot }
}
enum CodexCloudSync {
    enum OperationStatus {
        case notChecked, checking, synced
        var isSuccessful: Bool { self == .synced }
    }
}
enum CodexStatusClient {
    @discardableResult static func publishToCloud(_ snapshot: CodexStatusSnapshot) async -> CodexCloudSync.OperationStatus {
        RefreshTestState.published.append(snapshot)
        await withCheckedContinuation { RefreshTestState.cloudContinuations.append($0) }
        return .synced
    }
}
enum CodexFolderAccess {
    static let isSandboxed = false
    static let authorizedFolderURL: URL? = nil
    static func chooseFolder() -> Bool { false }
    static func clear() {}
}
final class MacStatusServer {
    static let port = NWEndpoint.Port(rawValue: 48219)!
    init(token: String, snapshotProvider: @escaping @MainActor @Sendable () -> CodexStatusSnapshot?) {}
    func start() throws {}
}
final class MacNavigationModel {}
final class MainWindowDockVisibilityController {}
final class MacUpdateChecker { func startAutomaticCheck() {} }
final class MacMenuBarController {
    init(store: MacStatusStore, navigation: MacNavigationModel, dockVisibilityController: MainWindowDockVisibilityController, updateChecker: MacUpdateChecker) {}
}
