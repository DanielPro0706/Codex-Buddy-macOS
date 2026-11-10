import AppKit
import Observation
import SwiftUI

@MainActor
final class MacLifecycleDelegate: NSObject, NSApplicationDelegate {
    let store = MacStatusStore()
    let snapReceiver = MacReceiver()
    let navigation = MacNavigationModel()
    let dockVisibilityController = MainWindowDockVisibilityController()
    let updateChecker = MacUpdateChecker()
    private var menuBarController: MacMenuBarController?
    private var wakeObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        store.start()
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.store.refreshForWake() }
        }
        if !CodexFolderAccess.isSandboxed { updateChecker.startAutomaticCheck() }
        menuBarController = MacMenuBarController(
            store: store,
            navigation: navigation,
            dockVisibilityController: dockVisibilityController,
            updateChecker: updateChecker,
            snapReceiver: snapReceiver
        )
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        Task { await store.refreshForWake() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        snapReceiver.stop()
        store.stop()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
    }
}

@MainActor
final class MainWindowDockVisibilityController {
    func prepareToShowMainWindow() {
        NSApplication.shared.setActivationPolicy(.regular)
    }

    func mainWindowDidClose() {
        NSApplication.shared.setActivationPolicy(.accessory)
    }
}

struct MainWindowDockLifecycleView: NSViewRepresentable {
    let controller: MainWindowDockVisibilityController

    func makeNSView(context: Context) -> MainWindowDockLifecycleNSView {
        MainWindowDockLifecycleNSView(controller: controller)
    }

    func updateNSView(_ nsView: MainWindowDockLifecycleNSView, context: Context) {}
}

final class MainWindowDockLifecycleNSView: NSView {
    private let controller: MainWindowDockVisibilityController
    private var closeObserver: NSObjectProtocol?

    init(controller: MainWindowDockVisibilityController) {
        self.controller = controller
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        if let closeObserver {
            NotificationCenter.default.removeObserver(closeObserver)
            self.closeObserver = nil
        }

        guard let window else { return }
        controller.prepareToShowMainWindow()
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.controller.mainWindowDidClose()
            }
        }
    }

    deinit {
        if let closeObserver {
            NotificationCenter.default.removeObserver(closeObserver)
        }
    }
}

@MainActor
private final class MacMenuBarController: NSObject {
    private let store: MacStatusStore
    private let updateChecker: MacUpdateChecker
    private let snapReceiver: MacReceiver
    private let item: NSStatusItem
    private let menu = NSMenu()
    private var labelWidthConstraint: NSLayoutConstraint?
    private var displayStyleObserver: NSObjectProtocol?
    private var hostedMenuContent: NSHostingView<MacMenuContent>?

    init(
        store: MacStatusStore,
        navigation: MacNavigationModel,
        dockVisibilityController: MainWindowDockVisibilityController,
        updateChecker: MacUpdateChecker,
        snapReceiver: MacReceiver
    ) {
        self.store = store
        self.updateChecker = updateChecker
        self.snapReceiver = snapReceiver
        item = NSStatusBar.system.statusItem(
            withLength: Self.measuredLabelWidth(for: store)
        )
        super.init()

        installLabel(store: store)
        installMenu(
            store: store,
            navigation: navigation,
            dockVisibilityController: dockVisibilityController
        )

        displayStyleObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: UserDefaults.standard,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateStatusItemWidth()
            }
        }

        observeSnapshotShape()
    }

    deinit {
        if let displayStyleObserver {
            NotificationCenter.default.removeObserver(displayStyleObserver)
        }
    }

    private static func measuredLabelWidth(for store: MacStatusStore) -> CGFloat {
        let measuringView = NSHostingView(rootView: MenuBarStatusLabel(store: store))
        return ceil(measuringView.fittingSize.width)
    }

    private func installLabel(store: MacStatusStore) {
        guard let button = item.button else { return }

        let hostedLabel = MenuBarPassthroughView(rootView: MenuBarStatusLabel(store: store))
        hostedLabel.translatesAutoresizingMaskIntoConstraints = false
        button.title = ""
        button.image = nil
        button.toolTip = "Codex"
        button.addSubview(hostedLabel)

        let widthConstraint = hostedLabel.widthAnchor.constraint(
            equalToConstant: Self.measuredLabelWidth(for: store)
        )
        labelWidthConstraint = widthConstraint
        NSLayoutConstraint.activate([
            hostedLabel.centerXAnchor.constraint(equalTo: button.centerXAnchor),
            hostedLabel.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            widthConstraint,
            hostedLabel.heightAnchor.constraint(equalToConstant: 18)
        ])

        item.menu = menu
    }

    private func installMenu(
        store: MacStatusStore,
        navigation: MacNavigationModel,
        dockVisibilityController: MainWindowDockVisibilityController
    ) {
        let hostedContent = NSHostingView(
            rootView: MacMenuContent(
                store: store,
                navigation: navigation,
                dockVisibilityController: dockVisibilityController,
                updateChecker: updateChecker,
                snapReceiver: snapReceiver
            )
        )
        let fittingSize = hostedContent.fittingSize
        hostedContent.frame.size = fittingSize
        hostedMenuContent = hostedContent

        let contentItem = NSMenuItem()
        contentItem.view = hostedContent
        menu.autoenablesItems = false
        menu.addItem(contentItem)
    }

    private func updateMenuContentSize() {
        guard let hostedMenuContent else { return }
        hostedMenuContent.invalidateIntrinsicContentSize()
        hostedMenuContent.layoutSubtreeIfNeeded()
        let fittingSize = hostedMenuContent.fittingSize
        guard hostedMenuContent.frame.size != fittingSize else { return }
        hostedMenuContent.frame.size = fittingSize
        menu.update()
    }

    private func updateStatusItemWidth() {
        let newWidth = Self.measuredLabelWidth(for: store)
        guard labelWidthConstraint?.constant != newWidth else { return }
        labelWidthConstraint?.constant = newWidth
        item.length = newWidth
    }

    private func observeSnapshotShape() {
        withObservationTracking {
            _ = store.snapshot?.windows.count
            _ = store.snapshot?.resetCredits?.availableCount
            _ = store.snapshot?.resetCredits?.availableCredits.count
            _ = store.cloudStatus
            _ = snapReceiver.isListening
            _ = snapReceiver.isReceivingEnabled
            _ = snapReceiver.requiresInvitation
            _ = snapReceiver.status
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.updateStatusItemWidth()
                self.updateMenuContentSize()
                self.observeSnapshotShape()
            }
        }
    }

}

private final class MenuBarPassthroughView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}
