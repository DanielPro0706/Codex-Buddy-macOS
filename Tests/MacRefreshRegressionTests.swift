import AppKit
import Foundation

@main struct MacRefreshRegressionTests {
    @MainActor static func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<100 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        assertionFailure("asynchronous refresh did not complete")
    }
    @MainActor static func main() async {
        let now = Date.now
        func snapshot(_ age: Double, _ used: Int) -> CodexStatusSnapshot {
            CodexStatusSnapshot(windows: [.init(kind: .fiveHour, usedPercent: used, durationMinutes: 300, resetsAt: nil)], planName: nil, capturedAt: now.addingTimeInterval(age), source: .sessionLog)
        }
        let fresh = snapshot(0, 20)
        let store = MacStatusStore(previewSnapshot: fresh)
        RefreshTestState.next = snapshot(-3600, 10)
        await store.refresh()
        assert(store.snapshot == fresh && RefreshTestState.saved == nil)
        print("PASS: older fallback cannot overwrite fresh displayed or cached usage")

        RefreshTestState.next = snapshot(1, 30)
        await store.refresh()
        await waitUntil { RefreshTestState.published.count == 1 }
        assert(!store.isRefreshing)
        RefreshTestState.next = snapshot(2, 40)
        await store.refresh()
        RefreshTestState.next = snapshot(3, 50)
        await store.refresh()
        assert(store.snapshot?.fiveHour?.usedPercent == 50 && RefreshTestState.published.count == 1)
        RefreshTestState.cloudContinuations.removeFirst().resume()
        await waitUntil { RefreshTestState.published.count == 2 }
        assert(RefreshTestState.published.last?.fiveHour?.usedPercent == 50)
        RefreshTestState.cloudContinuations.removeFirst().resume()
        print("PASS: stalled cloud upload does not block local refresh; uploads serialize and keep newest pending value")

        let delegate = MacLifecycleDelegate()
        RefreshTestState.next = snapshot(4, 60)
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        await waitUntil { delegate.store.snapshot?.fiveHour?.usedPercent == 60 }
        RefreshTestState.next = snapshot(5, 70)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        await waitUntil { delegate.store.snapshot?.fiveHour?.usedPercent == 70 }
        print("PASS: a workspace wake notification immediately refreshes usage")
        RefreshTestState.next = snapshot(6, 80)
        delegate.applicationDidBecomeActive(Notification(name: NSApplication.didBecomeActiveNotification))
        await waitUntil { delegate.store.snapshot?.fiveHour?.usedPercent == 80 }
        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        print("PASS: returning to foreground immediately refreshes usage")
    }
}
