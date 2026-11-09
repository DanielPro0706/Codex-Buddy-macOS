import AppKit
import CoreGraphics
import Foundation
import IOKit
import IOKit.ps

// The IOPS source runs on the main run loop. A notification bridge avoids storing an
// unretained Swift object in a C callback context that could outlive stop().
private nonisolated func macPowerDisplaySourceDidChange(_: UnsafeMutableRawPointer?) {
    Task { @MainActor in
        NotificationCenter.default.post(
            name: MacPowerDisplaySignals.powerSourceDidChangeNotification,
            object: nil
        )
    }
}

/// Read-only hardware samples plus event-derived session state.
/// Distributed lock/screensaver events provide no trustworthy initial snapshot.
@MainActor
final class MacPowerDisplaySignals: NSObject {
    struct Snapshot: Equatable, Sendable {
        // Unknown display/lid state keeps refresh available; unknown power uses
        // the battery cadence. Knowledge flags distinguish fallbacks from observations.
        var isOnACPower = false
        var lidClosed = false
        var hasExternalDisplay = true
        var isScreenLocked = false
        var isScreenSaverRunning = false
        var allExternalDisplaysAsleep = false

        var isPowerSourceKnown = false
        var isLidStateKnown = false
        var isDisplayConfigurationKnown = false
        var isScreenLockStateKnown = false
        var isScreenSaverStateKnown = false
    }

    private enum SessionEvent: String, CaseIterable {
        // Names verified against Hammerspoon's caffeinate watcher implementation:
        // https://github.com/Hammerspoon/hammerspoon/blob/master/extensions/caffeinate/libcaffeinate_watcher.m
        case screenLocked = "com.apple.screenIsLocked"
        case screenUnlocked = "com.apple.screenIsUnlocked"
        case screenSaverStarted = "com.apple.screensaver.didstart"
        case screenSaverWillStop = "com.apple.screensaver.willstop"
        case screenSaverStopped = "com.apple.screensaver.didstop"
    }

    fileprivate static let powerSourceDidChangeNotification = Notification.Name(
        "com.danieldev.CodexBuddyNew.localPowerSourceDidChange"
    )

    private(set) var current = Snapshot()
    private var onChange: (@MainActor () -> Void)?
    private var started = false
    private var powerSource: CFRunLoopSource?
    private var localObservers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []

    func start(onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
        guard !started else {
            resampleAndNotify()
            return
        }
        started = true

        // Events that happened while stopped cannot establish the current session state.
        current.isScreenLocked = false
        current.isScreenSaverRunning = false
        current.isScreenLockStateKnown = false
        current.isScreenSaverStateKnown = false

        let distributed = DistributedNotificationCenter.default()
        for event in SessionEvent.allCases {
            distributed.addObserver(
                self,
                selector: #selector(receiveSessionEvent(_:)),
                name: Notification.Name(event.rawValue),
                object: nil,
                suspensionBehavior: .deliverImmediately
            )
        }

        for name in [Self.powerSourceDidChangeNotification, NSApplication.didChangeScreenParametersNotification] {
            localObservers.append(NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.resampleAndNotify() }
            })
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.resampleAndNotify() }
            })
        }

        if let source = IOPSNotificationCreateRunLoopSource(macPowerDisplaySourceDidChange, nil)?.takeRetainedValue() {
            powerSource = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
        resampleAndNotify()
    }

    func stop() {
        started = false
        DistributedNotificationCenter.default().removeObserver(self)
        for observer in localObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        localObservers.removeAll()
        for observer in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        workspaceObservers.removeAll()
        if let source = powerSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            CFRunLoopSourceInvalidate(source)
            powerSource = nil
        }
        onChange = nil
    }

    /// Synchronously samples hardware; it never starts a process or performs network IO.
    /// The caller's local timer can use this while the lid/session is inactive.
    @discardableResult
    func refresh() -> Snapshot {
        let acPower = Self.readACPower()
        current.isOnACPower = acPower ?? false
        current.isPowerSourceKnown = acPower != nil

        let closed = Self.readLidClosed()
        current.lidClosed = closed ?? false
        current.isLidStateKnown = closed != nil

        if let displays = Self.readExternalDisplays() {
            current.hasExternalDisplay = displays.present
            current.allExternalDisplaysAsleep = displays.allAsleep
            current.isDisplayConfigurationKnown = true
        } else {
            current.hasExternalDisplay = true
            current.allExternalDisplaysAsleep = false
            current.isDisplayConfigurationKnown = false
        }
        return current
    }

    func snapshot() -> Snapshot { refresh() }

    private func resampleAndNotify() {
        guard started else { return }
        let previous = current
        refresh()
        if previous != current { onChange?() }
    }

    @objc private func receiveSessionEvent(_ notification: Notification) {
        guard started, let event = SessionEvent(rawValue: notification.name.rawValue) else { return }
        let previous = current
        switch event {
        case .screenLocked:
            current.isScreenLocked = true
            current.isScreenLockStateKnown = true
        case .screenUnlocked:
            current.isScreenLocked = false
            current.isScreenLockStateKnown = true
            current.isScreenSaverRunning = false
            current.isScreenSaverStateKnown = true
        case .screenSaverStarted:
            current.isScreenSaverRunning = true
            current.isScreenSaverStateKnown = true
        case .screenSaverWillStop:
            // It can still be active during this transition; wait for didstop.
            break
        case .screenSaverStopped:
            current.isScreenSaverRunning = false
            current.isScreenSaverStateKnown = true
        }
        refresh()
        if previous != current { onChange?() }
    }

    private static func readACPower() -> Bool? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? else {
            return nil
        }
        switch type {
        case kIOPSACPowerValue: return true
        case kIOPSBatteryPowerValue, kIOPMUPSPowerKey: return false
        default: return nil
        }
    }

    private static func readLidClosed() -> Bool? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }
        return IORegistryEntryCreateCFProperty(
            service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() as? Bool
    }

    private static func readExternalDisplays() -> (present: Bool, allAsleep: Bool)? {
        // Enumeration can race a hot-plug. Retry a bounded number of times instead
        // of accepting a truncated list as proof that no external display exists.
        for _ in 0..<3 {
            var count: UInt32 = 0
            guard CGGetOnlineDisplayList(0, nil, &count) == .success else { return nil }
            if count == 0 { return (false, false) }
            let capacity = count
            var ids = [CGDirectDisplayID](repeating: 0, count: Int(capacity))
            var returned: UInt32 = 0
            let result = ids.withUnsafeMutableBufferPointer {
                CGGetOnlineDisplayList(capacity, $0.baseAddress, &returned)
            }
            guard result == .success else { return nil }
            var latestCount: UInt32 = 0
            guard CGGetOnlineDisplayList(0, nil, &latestCount) == .success else { return nil }
            guard returned == latestCount, returned <= capacity else { continue }
            let online = Array(ids.prefix(Int(returned)))
            guard online.allSatisfy({ CGDisplayIsOnline($0) != 0 }) else { continue }
            let external = online.filter { CGDisplayIsBuiltin($0) == 0 }
            return (!external.isEmpty, !external.isEmpty && external.allSatisfy { CGDisplayIsAsleep($0) != 0 })
        }
        return nil
    }

    isolated deinit { stop() }
}
