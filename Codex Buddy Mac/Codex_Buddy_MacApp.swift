import SwiftUI
import Observation

enum MacMainTab: Hashable {
    case status
    case pairing
    case settings
}

@Observable
final class MacNavigationModel {
    var selectedTab: MacMainTab = .status
    var selectedFeature: BuddyTab = .limitis
}

enum MenuBarDisplayStyle: String, CaseIterable, Identifiable {
    static let storageKey = "menuBarDisplayStyle"

    case progressBar
    case rings

    var id: Self { self }

    var title: String {
        switch self {
        case .progressBar: "进度条"
        case .rings: "圆环"
        }
    }
}

@main
struct Codex_Buddy_MacApp: App {
    @NSApplicationDelegateAdaptor(MacLifecycleDelegate.self) private var lifecycleDelegate

    var body: some Scene {
        Window("Codex Buddy", id: "main") {
            ContentView(
                store: lifecycleDelegate.store,
                navigation: lifecycleDelegate.navigation,
                dockVisibilityController: lifecycleDelegate.dockVisibilityController,
                updateChecker: lifecycleDelegate.updateChecker,
                snapReceiver: lifecycleDelegate.snapReceiver
            )
        }
        .defaultSize(width: 860, height: 620)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        .commands {
            OpenMainWindowCommands(
                navigation: lifecycleDelegate.navigation,
                dockVisibilityController: lifecycleDelegate.dockVisibilityController
            )
        }

    }
}

struct MenuBarStatusLabel: View {
    let store: MacStatusStore
    @AppStorage(MenuBarDisplayStyle.storageKey) private var displayStyle = MenuBarDisplayStyle.progressBar

    var body: some View {
        let windows = store.snapshot?.windows ?? []
        HStack(spacing: displayStyle == .rings ? 5 : 3) {
            MenuBarCodexSymbol()

            if windows.isEmpty {
                Text("Codex --")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                switch displayStyle {
                case .progressBar:
                    VStack(spacing: 0) {
                        ForEach(Array(windows.prefix(2))) { window in
                            MenuBarUsageRow(window: window, isOnlyRow: windows.count == 1)
                        }
                    }
                case .rings:
                    HStack(spacing: 5) {
                        ForEach(Array(windows.prefix(2))) { window in
                            MenuBarUsageRing(window: window, isOnlyRing: windows.count == 1)
                        }
                    }
                }
            }
        }
        .foregroundStyle(.primary)
        .fixedSize(horizontal: true, vertical: false)
        .frame(height: 18)
        .contentShape(Rectangle())
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        let windows = store.snapshot?.windows ?? []
        guard !windows.isEmpty else { return "Codex 暂无额度" }
        return windows.prefix(2)
            .map { "\($0.kind.shortLabel) 剩余百分之 \($0.remainingPercent)" }
            .joined(separator: "，")
    }
}

private struct MenuBarCodexSymbol: View {
    var body: some View {
        CodexSymbol(size: 15)
    }
}

private struct MenuBarUsageRing: View {
    let window: CodexUsageWindow
    let isOnlyRing: Bool

    var body: some View {
        HStack(spacing: 6) {
            ZStack {
                Circle()
                    .stroke(Color.primary.opacity(0.18), lineWidth: 2.5)
                Circle()
                    .trim(from: 0, to: window.remainingFraction)
                    .stroke(
                        healthColor,
                        style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                Text(window.kind.shortLabel)
                    .font(.system(size: isOnlyRing ? 7 : 6, weight: .semibold, design: .rounded))
            }
            .frame(width: isOnlyRing ? 18 : 17, height: isOnlyRing ? 18 : 17)

            Text("\(window.remainingPercent)%")
                .font(.system(size: isOnlyRing ? 10 : 8, weight: .regular))
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    private var healthColor: Color {
        CodexHealthLevel(remainingPercent: window.remainingPercent).color
    }
}

private struct MenuBarUsageRow: View {
    let window: CodexUsageWindow
    let isOnlyRow: Bool

    var body: some View {
        HStack(spacing: 0) {
            Text(window.kind.shortLabel)
                .monospaced()
                .frame(width: 18, alignment: .trailing)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.18))
                Capsule()
                    .fill(healthColor)
                    .frame(width: 30 * window.remainingFraction)
            }
            .frame(width: 30, height: 5)
            .padding(.leading, 4)

            Text("\(window.remainingPercent)%")
                .font(.system(size: isOnlyRow ? 10 : 8, weight: .regular, design: .rounded))
                .fontWeight(.regular)
                .monospacedDigit()
                .frame(width: 28, alignment: .leading)
                .padding(.leading, 4)
        }
        .font(.system(size: isOnlyRow ? 9 : 7, weight: .semibold, design: .rounded))
        .frame(width: 84, alignment: .leading)
        .frame(height: isOnlyRow ? 18 : 9)
    }

    private var healthColor: Color {
        CodexHealthLevel(remainingPercent: window.remainingPercent).color
    }
}

struct OpenMainWindowCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    let navigation: MacNavigationModel
    let dockVisibilityController: MainWindowDockVisibilityController

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("打开主窗口") {
                openMainWindow(tab: .status)
            }
            .keyboardShortcut("0", modifiers: .command)
        }

        CommandGroup(replacing: .appSettings) {
            Button("设置…") {
                openMainWindow(tab: .settings)
            }
            .keyboardShortcut(",", modifiers: .command)
        }
    }

    private func openMainWindow(tab: MacMainTab) {
        navigation.selectedFeature = .limitis
        navigation.selectedTab = tab
        dockVisibilityController.prepareToShowMainWindow()
        NSApplication.shared.activate(ignoringOtherApps: true)
        openWindow(id: "main")
    }
}
