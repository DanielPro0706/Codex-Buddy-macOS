import AppKit
import Foundation
import Network

@MainActor enum RefreshTestState {
    static var next = CodexStatusSnapshot.preview
    static var saved: CodexStatusSnapshot?
    static var reads = 0
    static var suspends = 0
    static var keepAliveReads: [Bool] = []
    static var environment = MacRefreshEnvironment(allDisplaysAsleep: false, activity: .inactive)
    static var monitors: [MacRefreshEnvironmentMonitor] = []
    static var published: [CodexStatusSnapshot] = []
    static var cloudContinuations: [CheckedContinuation<Void, Never>] = []
}
actor LocalCodexStatusReader {
    func read(keepingSessionAlive: Bool = true) async throws -> CodexStatusSnapshot {
        await MainActor.run {
            RefreshTestState.reads += 1
            RefreshTestState.keepAliveReads.append(keepingSessionAlive)
            return RefreshTestState.next
        }
    }
    func suspend() async {
        await MainActor.run { RefreshTestState.suspends += 1 }
    }
}
@MainActor final class MacRefreshEnvironmentMonitor {
    private var onChange: ((MacRefreshEnvironment) -> Void)?
    init(activityMonitoringEnabled: Bool = true) {}
    var current: MacRefreshEnvironment { RefreshTestState.environment }
    func start(onChange: @escaping @MainActor (MacRefreshEnvironment) -> Void) {
        self.onChange = onChange
        RefreshTestState.monitors.append(self)
        onChange(current)
    }
    func stop() { onChange = nil }
    func refresh() async { onChange?(current) }
    func simulate(_ environment: MacRefreshEnvironment) {
        RefreshTestState.environment = environment
        onChange?(environment)
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
    func stop() {}
}
final class MacNavigationModel {}
final class MainWindowDockVisibilityController {}
final class MacUpdateChecker { func startAutomaticCheck() {} }
final class MacMenuBarController {
    init(store: MacStatusStore, navigation: MacNavigationModel, dockVisibilityController: MainWindowDockVisibilityController, updateChecker: MacUpdateChecker) {}
}

@MainActor final class MacReceiver {
    func stop() {}
}
