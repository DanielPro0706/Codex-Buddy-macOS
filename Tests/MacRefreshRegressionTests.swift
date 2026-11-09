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
        print("PASS: returning to foreground immediately refreshes usage")

        let monitor = RefreshTestState.monitors.last!
        let readsBeforeSleep = RefreshTestState.reads
        let suspendsBeforeSleep = RefreshTestState.suspends
        monitor.simulate(.init(allDisplaysAsleep: true, activity: .inactive))
        await waitUntil { RefreshTestState.suspends > suspendsBeforeSleep }
        try? await Task.sleep(for: .milliseconds(50))
        assert(RefreshTestState.reads == readsBeforeSleep, "entering display-off idle must close the client without immediately restarting it")
        print("PASS: display-off idle suspends the live client and waits for its scheduled check")

        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        try? await Task.sleep(for: .milliseconds(50))
        assert(RefreshTestState.reads == readsBeforeSleep, "a display-off maintenance wake must preserve the idle deadline")
        print("PASS: maintenance wakes with every display asleep do not restart quota polling")

        RefreshTestState.next = snapshot(7, 81)
        await delegate.store.refresh()
        assert(RefreshTestState.keepAliveReads.last == false, "a low-frequency/manual read must not leave autonomous CLI workers online")
        print("PASS: refreshes in low-frequency mode are explicitly one-shot")

        RefreshTestState.next = snapshot(8, 82)
        monitor.simulate(.init(allDisplaysAsleep: true, activity: .active))
        await waitUntil { delegate.store.snapshot?.fiveHour?.usedPercent == 82 }
        assert(RefreshTestState.keepAliveReads.last == true)
        print("PASS: a new active turn immediately restores normal persistent refresh while every display is asleep")

        let beforeSecondSleep = RefreshTestState.suspends
        monitor.simulate(.init(allDisplaysAsleep: true, activity: .inactive))
        await waitUntil { RefreshTestState.suspends > beforeSecondSleep }
        RefreshTestState.next = snapshot(9, 83)
        monitor.simulate(.init(allDisplaysAsleep: true, activity: .unknown))
        await waitUntil { delegate.store.snapshot?.fiveHour?.usedPercent == 83 }
        assert(RefreshTestState.keepAliveReads.last == true)
        print("PASS: unknown activity cannot leave an active conversation throttled as idle")

        let beforeThirdSleep = RefreshTestState.suspends
        monitor.simulate(.init(allDisplaysAsleep: true, activity: .inactive))
        await waitUntil { RefreshTestState.suspends > beforeThirdSleep }
        RefreshTestState.next = snapshot(10, 84)
        monitor.simulate(.init(allDisplaysAsleep: false, activity: .inactive))
        await waitUntil { delegate.store.snapshot?.fiveHour?.usedPercent == 84 }
        assert(RefreshTestState.keepAliveReads.last == true)
        print("PASS: waking any display immediately restores normal persistent refresh")

        let beforeBattery = RefreshTestState.suspends
        var battery = RefreshTestState.environment
        battery.isOnACPower = false
        battery.isPowerSourceKnown = true
        RefreshTestState.next = snapshot(11, 85)
        monitor.simulate(battery)
        await waitUntil { delegate.store.snapshot?.fiveHour?.usedPercent == 85 }
        assert(RefreshTestState.keepAliveReads.last == true && RefreshTestState.suspends == beforeBattery)
        print("PASS: changing to battery reschedules normal refresh without restarting its live session")

        var lockedClamshell = battery
        lockedClamshell.lidClosed = true
        lockedClamshell.hasExternalDisplay = true
        lockedClamshell.isScreenLocked = true
        let beforeLock = RefreshTestState.suspends
        monitor.simulate(lockedClamshell)
        await waitUntil { RefreshTestState.suspends > beforeLock }
        let readsWhileLocked = RefreshTestState.reads
        try? await Task.sleep(for: .milliseconds(50))
        assert(RefreshTestState.reads == readsWhileLocked)
        print("PASS: a locked external display plus a closed lid enters backoff even while the display is still powered on")

        RefreshTestState.next = snapshot(12, 86)
        lockedClamshell.isScreenLocked = false
        monitor.simulate(lockedClamshell)
        await waitUntil { delegate.store.snapshot?.fiveHour?.usedPercent == 86 }
        assert(RefreshTestState.keepAliveReads.last == true)

        var noExternal = lockedClamshell
        noExternal.hasExternalDisplay = false
        let beforeNoExternal = RefreshTestState.suspends
        monitor.simulate(noExternal)
        await waitUntil { RefreshTestState.suspends > beforeNoExternal }
        RefreshTestState.next = snapshot(13, 87)
        noExternal.activity = .active
        monitor.simulate(noExternal)
        await waitUntil { delegate.store.snapshot?.fiveHour?.usedPercent == 87 }
        assert(RefreshTestState.keepAliveReads.last == true)
        print("PASS: no external display plus a closed lid backs off; starting a task immediately restores the battery cadence")

        let beforeStop = RefreshTestState.suspends
        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        await waitUntil { RefreshTestState.suspends > beforeStop }
        print("PASS: application termination stops polling and its retained quota session")
    }
}
