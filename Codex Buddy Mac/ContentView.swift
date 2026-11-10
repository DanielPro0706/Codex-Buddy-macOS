import AppKit
import SwiftUI

struct ContentView: View {
    let store: MacStatusStore
    let navigation: MacNavigationModel
    let dockVisibilityController: MainWindowDockVisibilityController
    let updateChecker: MacUpdateChecker
    let snapReceiver: MacReceiver

    var body: some View {
        @Bindable var navigation = navigation
        TabView(selection: $navigation.selectedFeature) {
            Tab("limitis", systemImage: "gauge.with.dots.needle.67percent", value: .limitis) {
                LimitisMacView(store: store, navigation: navigation,
                               dockVisibilityController: dockVisibilityController,
                               updateChecker: updateChecker)
            }
            Tab("snapinsert", systemImage: "camera.on.rectangle", value: .snapinsert) {
                SnapInsertMacTab(receiver: snapReceiver)
            }
            Tab("CloudSpace", systemImage: "icloud", value: .cloudSpace) {
                CloudSpaceTab()
            }
        }
        .frame(minWidth: 760, minHeight: 560)
        .background {
            MainWindowDockLifecycleView(controller: dockVisibilityController)
                .frame(width: 0, height: 0)
        }
    }
}

struct LimitisMacView: View {
    let store: MacStatusStore
    let navigation: MacNavigationModel
    let dockVisibilityController: MainWindowDockVisibilityController
    let updateChecker: MacUpdateChecker

    var body: some View {
        NavigationSplitView {
            MacSidebar(selection: sidebarSelection)
        } detail: {
            MacDetailView(
                selection: navigation.selectedTab,
                store: store,
                updateChecker: updateChecker
            )
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 760, minHeight: 520)
        .background {
            MainWindowDockLifecycleView(controller: dockVisibilityController)
                .frame(width: 0, height: 0)
        }
        .task { store.start() }
    }

    private var sidebarSelection: Binding<MacMainTab?> {
        Binding(
            get: { navigation.selectedTab },
            set: { selectedTab in
                if let selectedTab {
                    navigation.selectedTab = selectedTab
                }
            }
        )
    }
}

private struct MacSidebar: View {
    @Binding var selection: MacMainTab?

    var body: some View {
        List(selection: $selection) {
            NavigationLink(value: MacMainTab.status) {
                Label("状态", systemImage: "gauge.with.dots.needle.67percent")
            }

            NavigationLink(value: MacMainTab.pairing) {
                Label("连接", systemImage: "iphone.and.arrow.forward")
            }

            NavigationLink(value: MacMainTab.settings) {
                Label("设置", systemImage: "gearshape")
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Codex Buddy")
        .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 260)
    }
}

private struct MacDetailView: View {
    let selection: MacMainTab
    let store: MacStatusStore
    let updateChecker: MacUpdateChecker

    var body: some View {
        switch selection {
        case .status:
            MacOverviewView(store: store)
        case .pairing:
            PairingDetailsView(connection: store.pairingConnection)
        case .settings:
            MacSettingsView(store: store, updateChecker: updateChecker)
        }
    }
}

struct MacOverviewView: View {
    let store: MacStatusStore
    @State private var showingExample = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                CodexSnapshotHeader(
                    planName: store.snapshot?.planName,
                    capturedAt: store.snapshot?.capturedAt,
                    isStale: store.snapshot?.isStale ?? false
                )

                MacStatusGlassContent(
                    snapshot: store.snapshot,
                    cloudStatus: store.cloudStatus
                )

                HStack {
                    Label(store.statusText, systemImage: store.isRefreshing ? "arrow.trianglehead.2.clockwise.rotate.90" : "circle.fill")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("查看示例", systemImage: "eye") {
                        showingExample = true
                    }
                    Button("立即读取", systemImage: "arrow.clockwise") {
                        Task { await store.refresh() }
                    }
                    .disabled(store.isRefreshing)
                }
            }
            .padding(28)
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("limitis")
        .sheet(isPresented: $showingExample) { MacExampleStatusView() }
    }
}

private struct MacExampleStatusView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Label("演示数据", systemImage: "eye")
                        .font(.title2.weight(.semibold))
                    Spacer()
                    Button("关闭") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
                Text("以下为虚构的额度示例，不代表你的账户。打开此示例不会查询额度或替换真实状态。")
                    .foregroundStyle(.secondary)
                CodexSnapshotHeader(
                    planName: CodexStatusSnapshot.preview.planName,
                    capturedAt: CodexStatusSnapshot.preview.capturedAt,
                    isStale: false
                )
                MacStatusGlassContent(snapshot: .preview, cloudStatus: .notChecked, showsCloudStatus: false)
            }
            .padding(28)
        }
        .frame(width: 600, height: 650)
    }
}

private struct MacStatusGlassContent: View {
    let snapshot: CodexStatusSnapshot?
    let cloudStatus: CodexCloudSync.OperationStatus
    var showsCloudStatus = true

    var body: some View {
        GlassEffectContainer(spacing: 18) {
            VStack(alignment: .leading, spacing: 18) {
                if let snapshot, !snapshot.windows.isEmpty {
                    ForEach(snapshot.windows) { window in
                        CodexUsageCard(
                            window: window,
                            showsSurface: false,
                            prominentHeader: true
                        )
                            .glassEffect(
                                .regular,
                                in: RoundedRectangle(cornerRadius: 24, style: .continuous)
                            )
                    }

                    if let resetCredits = snapshot.resetCredits,
                       resetCredits.availableCount > 0 {
                        CodexResetCreditsCard(
                            summary: resetCredits,
                            showsSurface: false,
                            prominent: true
                        )
                            .glassEffect(
                                .regular,
                                in: RoundedRectangle(cornerRadius: 24, style: .continuous)
                            )
                    }

                    if let creditsBalance = snapshot.integerCreditsBalance {
                        MacCreditsBalanceRow(
                            balance: creditsBalance,
                            menuStyle: false
                        )
                        .glassEffect(
                            .regular,
                            in: RoundedRectangle(cornerRadius: 24, style: .continuous)
                        )
                    }
                } else {
                    ContentUnavailableView {
                        Label {
                            Text("尚未读取到 Codex 状态")
                        } icon: {
                            CodexSymbol(size: 28)
                        }
                    } description: {
                        Text("请确认本机已安装并登录 Codex，然后重新读取。")
                    }
                    .frame(maxWidth: .infinity, minHeight: 220)
                    .padding(18)
                    .glassEffect(
                        .regular,
                        in: RoundedRectangle(cornerRadius: 24, style: .continuous)
                    )
                }

                if showsCloudStatus {
                    CodexCloudStatusView(status: cloudStatus)
                        .glassEffect(
                            .regular,
                            in: RoundedRectangle(cornerRadius: 24, style: .continuous)
                        )
                }
            }
        }
    }
}

struct PairingDetailsView: View {
    let connection: MacConnection
    @State private var copiedField: String?

    var body: some View {
        Form {
            Section("在 iPhone 上连接") {
                Text("让 Mac 与 iPhone 连接同一局域网，然后在 iPhone 的“连接”页面填写以下信息。")
                    .foregroundStyle(.secondary)

                if let pairingURL = connection.pairingURL {
                    HStack {
                        Spacer()
                        PairingQRCodeView(payload: pairingURL.absoluteString)
                            .frame(width: 210, height: 210)
                        Spacer()
                    }
                    Text("在 iPhone 上选择“扫描配对二维码”，即可自动填写地址和令牌。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                }

                LabeledContent("Mac 地址") {
                    Text(connection.baseURL.absoluteString)
                        .textSelection(.enabled)
                }
                LabeledContent("访问令牌") {
                    Text(connection.accessToken)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }

                HStack {
                    Button("复制地址") {
                        copy(connection.baseURL.absoluteString, field: "地址")
                    }
                    Button("复制令牌") {
                        copy(connection.accessToken, field: "令牌")
                    }
                    if let copiedField {
                        Text("已复制\(copiedField)")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("安全说明") {
                Text("服务仅在当前 Mac 的局域网端口监听；所有状态请求都必须携带此随机令牌。")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("连接 iPhone")
    }

    private func copy(_ value: String, field: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        copiedField = field
    }
}

struct MacSettingsView: View {
    let store: MacStatusStore
    let updateChecker: MacUpdateChecker

    var body: some View {
        MenuBarSettingsView(store: store, updateChecker: updateChecker)
            .navigationTitle("设置")
    }
}

private struct MenuBarSettingsView: View {
    let store: MacStatusStore
    let updateChecker: MacUpdateChecker
    @AppStorage(MenuBarDisplayStyle.storageKey) private var displayStyle = MenuBarDisplayStyle.progressBar
    @State private var showingExample = false

    var body: some View {
        Form {
            Section("菜单栏") {
                Picker("额度样式", selection: $displayStyle) {
                    ForEach(MenuBarDisplayStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
                .pickerStyle(.segmented)

                Text("进度条显示精确百分比；圆环用更紧凑的方式同时展示 5h 与 7d 额度。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if store.usesSandboxedFolderAccess {
                Section {
                    LabeledContent("已授权文件夹") {
                        Text(store.authorizedCodexFolderPath ?? "尚未选择")
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    HStack {
                        Button("选择 .codex 文件夹", systemImage: "folder.badge.plus") {
                            store.chooseCodexFolder()
                        }
                        if store.authorizedCodexFolderPath != nil {
                            Button("移除授权", systemImage: "xmark.circle", role: .destructive) {
                                store.clearCodexFolderAuthorization()
                            }
                        }
                    }
                } header: {
                    Text("Codex 数据访问")
                } footer: {
                    Text("Mac App Store 版受系统沙盒保护，只读取你明确选择的文件夹中的额度事件。")
                }
            }

            Section {
                CodexCloudStatusView(status: store.cloudStatus, compact: true)
                    .padding(.horizontal, -12)
            } header: {
                Text("iCloud 同步")
            } footer: {
                Text("额度变化时同步至 iCloud；未变化时至少间隔五分钟再次发布。iPhone 使用同一 Apple Account 可读取最新快照。开发者的推送服务还保存快照与推送路由信息，详见隐私政策。")
            }

            Section {
                LabeledContent("当前版本") {
                    Text(updateChecker.installedVersionDescription)
                        .foregroundStyle(.secondary)
                }

                if updateChecker.usesMacAppStoreUpdates {
                    Text("此版本通过 Mac App Store 更新。")
                        .foregroundStyle(.secondary)
                } else {
                    UpdateStatusView(updateChecker: updateChecker)
                }
            } header: {
                Text("软件更新")
            } footer: {
                Text(updateChecker.usesMacAppStoreUpdates
                    ? "请使用 Mac App Store 的更新功能更新此应用。"
                    : "Codex Buddy 会在启动后检查 GitHub 上的最新 macOS 完整版。")
            }

            Section("帮助") {
                Button("查看示例", systemImage: "eye") { showingExample = true }
                Link("隐私政策", destination: URL(string: "https://github.com/DanielPro0706/Codex-Buddy-macOS/blob/main/docs/PRIVACY.md")!)
                Link("支持与反馈", destination: URL(string: "https://github.com/DanielPro0706/Codex-Buddy-macOS/blob/main/docs/SUPPORT.md")!)
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .sheet(isPresented: $showingExample) { MacExampleStatusView() }
    }
}

struct MacMenuContent: View {
    let store: MacStatusStore
    let navigation: MacNavigationModel
    let dockVisibilityController: MainWindowDockVisibilityController
    let updateChecker: MacUpdateChecker
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            MacMenuHeader(
                planName: store.snapshot?.planName,
                capturedAt: store.snapshot?.capturedAt,
                isStale: store.snapshot?.isStale ?? false
            )

            if let snapshot = store.snapshot {
                VStack(spacing: 10) {
                    ForEach(snapshot.windows) { window in
                        MacCompactUsageRow(window: window)
                    }

                    if let resetCredits = snapshot.resetCredits,
                       resetCredits.availableCount > 0 {
                        CodexResetCreditsCard(
                            summary: resetCredits,
                            menuStyle: true
                        )
                    }

                    if let creditsBalance = snapshot.integerCreditsBalance {
                        MacCreditsBalanceRow(
                            balance: creditsBalance,
                            menuStyle: true
                        )
                    }
                }
            } else {
                Text("等待首次读取")
                    .frame(maxWidth: .infinity, minHeight: 80)
                    .foregroundStyle(.secondary)
            }

            CodexCloudStatusView(status: store.cloudStatus, compact: true)
                .padding(.horizontal, 1)
                .padding(.vertical, 2)
                .background(
                    .quaternary.opacity(0.45),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                )

            Divider()

            HStack {
                Button("显示配对二维码", systemImage: "qrcode") {
                    openMainWindow(tab: .pairing)
                }
                .help("显示配对二维码")

                Button("打开主窗口", systemImage: "macwindow") {
                    openMainWindow(tab: .status)
                }
                .help("打开主窗口")

                Button("刷新", systemImage: "arrow.clockwise") {
                    Task { await store.refresh() }
                }
                .disabled(store.isRefreshing)
                .help("刷新")

                Spacer()

                Button {
                    openMainWindow(tab: .settings)
                } label: {
                    Label("设置", systemImage: "gearshape")
                }
                .help("设置")

                if !updateChecker.usesMacAppStoreUpdates {
                    Button("检查更新", systemImage: "arrow.triangle.2.circlepath") {
                        Task { await updateChecker.checkForUpdates() }
                    }
                    .disabled(updateChecker.state == .checking)
                    .help("检查更新")
                }

                Button("退出", systemImage: "power") {
                    NSApplication.shared.terminate(nil)
                }
                .help("退出")
            }
            .buttonStyle(.borderless)
            .labelStyle(.iconOnly)
            .font(.system(size: 15, weight: .medium))
        }
        .padding(16)
        .frame(width: 330)
        .task { store.start() }
    }

    private func openMainWindow(tab: MacMainTab) {
        navigation.selectedFeature = .limitis
        navigation.selectedTab = tab
        dockVisibilityController.prepareToShowMainWindow()
        NSApplication.shared.activate(ignoringOtherApps: true)
        openWindow(id: "main")
    }
}

private struct UpdateStatusView: View {
    let updateChecker: MacUpdateChecker

    var body: some View {
        switch updateChecker.state {
        case .idle:
            checkButton
        case .checking:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("正在检查更新…")
                    .foregroundStyle(.secondary)
            }
        case .upToDate:
            HStack {
                Label("已是最新版本", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Spacer()
                checkButton
            }
        case .updateAvailable(let release):
            VStack(alignment: .leading, spacing: 9) {
                Label("可更新到 \(release.displayVersion)", systemImage: "arrow.down.circle.fill")
                    .foregroundStyle(.blue)
                if let body = release.body, !body.isEmpty {
                    Text(body)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                HStack {
                    Button("下载更新") {
                        updateChecker.openDownload(for: release)
                    }
                    .buttonStyle(.borderedProminent)
                    Button("重新检查") {
                        Task { await updateChecker.checkForUpdates() }
                    }
                }
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                Label("检查更新失败", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                checkButton
            }
        }
    }

    private var checkButton: some View {
        Button("检查更新", systemImage: "arrow.triangle.2.circlepath") {
            Task { await updateChecker.checkForUpdates() }
        }
    }
}

private struct MacMenuHeader: View {
    let planName: String?
    let capturedAt: Date?
    let isStale: Bool

    var body: some View {
        HStack(spacing: 12) {
            CodexSymbol(size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text("Codex Buddy")
                    .font(.title3.weight(.semibold))
                if let planName, !planName.isEmpty {
                    Text(planName.uppercased())
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let capturedAt {
                HStack(spacing: 4) {
                    Image(systemName: isStale ? "exclamationmark.triangle.fill" : "clock.arrow.circlepath")
                    if isStale {
                        Text("状态可能已过期")
                    } else {
                        Text("更新于")
                    }
                    Text(capturedAt, style: .time)
                }
                .font(.caption)
                .foregroundStyle(isStale ? .orange : .secondary)
            }
        }
    }
}

private struct MacCompactUsageRow: View {
    let window: CodexUsageWindow
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                Label(window.kind.title, systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                    .font(.headline)
                Spacer()
                Text(window.remainingPercent, format: .percent.scale(1))
                    .font(.title2.bold())
                    .foregroundStyle(percentageColor)
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(colorScheme == .dark ? 0.18 : 0.12))
                    Capsule()
                        .fill(healthColor)
                        .frame(width: geometry.size.width * window.remainingFraction)
                }
            }
            .frame(height: 10)

            if let resetsAt = window.resetsAt {
                CodexRecoveryText(resetsAt: resetsAt)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 14)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var healthColor: Color {
        healthLevel.color
    }

    private var percentageColor: Color {
        let baseColor: NSColor = switch healthLevel {
        case .good: .systemGreen
        case .attention: .systemOrange
        case .low: .systemRed
        }
        let contrastColor: NSColor = colorScheme == .dark ? .white : .black
        let adjustedColor = baseColor.blended(withFraction: 0.16, of: contrastColor) ?? baseColor
        return Color(nsColor: adjustedColor)
    }

    private var healthLevel: CodexHealthLevel {
        CodexHealthLevel(remainingPercent: window.remainingPercent)
    }
}

private struct MacCreditsBalanceRow: View {
    let balance: String
    let menuStyle: Bool

    var body: some View {
        HStack(spacing: 10) {
            Label("Credits", systemImage: "creditcard")
                .font(.headline)

            Spacer(minLength: 12)

            Text(balance)
                .font(menuStyle ? .title2.monospacedDigit() : .title3.monospacedDigit())
                .fontWeight(menuStyle ? .regular : .semibold)
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, menuStyle ? 13 : 18)
        .padding(.vertical, menuStyle ? 14 : 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if menuStyle {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.quaternary.opacity(0.45))
            }
        }
    }
}

#Preview {
    LimitisMacView(
        store: MacStatusStore(previewSnapshot: .preview),
        navigation: MacNavigationModel(),
        dockVisibilityController: MainWindowDockVisibilityController(),
        updateChecker: MacUpdateChecker()
    )
}
