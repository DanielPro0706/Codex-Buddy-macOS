import AppKit
import SwiftUI

struct ContentView: View {
    let store: MacStatusStore
    let navigation: MacNavigationModel
    let dockVisibilityController: MainWindowDockVisibilityController
    let updateChecker: MacUpdateChecker
    let snapReceiver: MacReceiver

    var body: some View {
        NavigationSplitView {
            MacSidebar(selection: sidebarSelection)
        } detail: {
            switch navigation.selectedFeature {
            case .limits, .cloudSpace:
                LimitsMacView(store: store, navigation: navigation, updateChecker: updateChecker)
            case .snapinsert:
                SnapInsertMacTab(receiver: snapReceiver) {
                    navigation.selectedFeature = .connection
                }
            case .connection:
                PairingDetailsView(connection: store.pairingConnection, snapReceiver: snapReceiver)
            case .settings:
                MacSettingsView(store: store, updateChecker: updateChecker, snapReceiver: snapReceiver) {
                    navigation.selectedFeature = .connection
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 760, minHeight: 560)
        .background {
            MainWindowDockLifecycleView(controller: dockVisibilityController)
                .frame(width: 0, height: 0)
        }
        .onChange(of: navigation.selectedFeature, initial: true) { _, selectedFeature in
            if selectedFeature == .cloudSpace {
                navigation.selectedFeature = .limits
            } else if selectedFeature == .limits {
                navigation.selectedTab = .status
            }
        }
        .onChange(of: navigation.selectedTab, initial: true) { _, tab in
            if tab == .settings { navigation.selectedFeature = .settings }
            else if tab == .pairing { navigation.selectedFeature = .connection }
        }
    }

    private var sidebarSelection: Binding<BuddyTab?> {
        Binding(
            get: { navigation.selectedFeature == .cloudSpace ? .limits : navigation.selectedFeature },
            set: { selectedFeature in
                if let selectedFeature {
                    navigation.selectedFeature = selectedFeature
                }
            }
        )
    }
}

struct LimitsMacView: View {
    let store: MacStatusStore
    let navigation: MacNavigationModel
    let updateChecker: MacUpdateChecker

    var body: some View {
        MacOverviewView(store: store)
    }
}

private struct MacSidebar: View {
    @Binding var selection: BuddyTab?

    var body: some View {
        List(selection: $selection) {
            NavigationLink(value: BuddyTab.limits) {
                Label("Limits", systemImage: "gauge.with.dots.needle.67percent")
            }

            NavigationLink(value: BuddyTab.snapinsert) {
                Label("SnapInsert", systemImage: "camera.on.rectangle")
            }

            NavigationLink(value: BuddyTab.connection) {
                Label("连接", systemImage: "iphone.and.arrow.forward")
            }

            NavigationLink(value: BuddyTab.settings) {
                Label("设置", systemImage: "gearshape")
            }

        }
        .listStyle(.sidebar)
        .navigationTitle("Codex Buddy")
        .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 260)
    }
}

struct MacOverviewView: View {
    let store: MacStatusStore

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
        .font(BuddyMacTypography.body)
        .background { BuddyPageBackground() }
        .navigationTitle("Limits")
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
    let snapReceiver: MacReceiver
    @State private var copiedField: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BuddyStyle.contentSpacing) {
                HStack(spacing: 12) {
                    Image(systemName: "iphone.and.arrow.forward")
                        .font(.title2)
                        .foregroundStyle(.primary)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("连接 iPhone")
                            .font(BuddyMacTypography.pageTitle)
                        Text("一次扫码，连接 Limits 与 SnapInsert。")
                            .font(BuddyMacTypography.detail)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }

                pairingCard
                manualConnectionCard
                securityCard
            }
            .padding(BuddyStyle.pagePadding)
            .frame(maxWidth: BuddyStyle.contentWidth)
            .frame(maxWidth: .infinity)
        }
        .font(BuddyMacTypography.body)
        .background { BuddyPageBackground() }
        .navigationTitle("连接 iPhone")
    }

    private var pairingCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("在 iPhone 上连接", systemImage: "qrcode.viewfinder")
                .font(BuddyMacTypography.cardTitle)
            Text("在 iPhone 上扫描一次，即可保存 Limits 和 SnapInsert 的连接。Limits 直连时，两端需要在同一网络。")
                .font(BuddyMacTypography.detail)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let snapPairing = snapReceiver.pairing,
               let pairingURL = try? BuddyPairingPayload.unifiedURL(limits: connection, snapInsert: snapPairing) {
                PairingQRCodeView(payload: pairingURL.absoluteString)
                    .frame(maxWidth: 260)
                    .frame(maxWidth: .infinity)
                Text("从 Limits 或 SnapInsert 扫描，均使用这一个二维码。请勿分享。")
                    .font(BuddyMacTypography.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .center)
            } else {
                Label("统一配对信息尚未就绪，请在 SnapInsert 页面检查接收状态。", systemImage: "exclamationmark.triangle")
                    .font(BuddyMacTypography.detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(BuddyStyle.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .buddyCardSurface()
    }

    private var manualConnectionCard: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 18) {
                    Text("Mac 地址")
                        .fixedSize()
                    Spacer(minLength: 0)
                    Text(connection.baseURL.absoluteString)
                        .multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                HStack(alignment: .top, spacing: 18) {
                    Text("访问令牌")
                        .fixedSize()
                    Spacer(minLength: 0)
                    Text(connection.accessToken)
                        .font(.system(.body, design: .monospaced))
                        .multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
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
                .buttonStyle(.bordered)
            }
            .padding(.top, 14)
        } label: {
            Label("手动连接 Limits", systemImage: "link")
                .font(BuddyMacTypography.cardTitle)
        }
        .padding(BuddyStyle.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .buddyCardSurface()
    }

    private var securityCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("安全说明", systemImage: "lock.shield")
                .font(BuddyMacTypography.cardTitle)
            Text("二维码包含连接凭据，仅用于你自己的设备。额度直连使用局域网访问令牌；照片使用独立密钥端到端加密。")
                .font(BuddyMacTypography.detail)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(BuddyStyle.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .buddyCardSurface()
    }

    private func copy(_ value: String, field: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        copiedField = field
    }
}

struct MacMenuContent: View {
    let store: MacStatusStore
    let navigation: MacNavigationModel
    let dockVisibilityController: MainWindowDockVisibilityController
    let updateChecker: MacUpdateChecker
    let snapReceiver: MacReceiver
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

            MacSnapInsertMenuStatus(receiver: snapReceiver, open: openSnapInsert)

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
        if tab == .pairing {
            navigation.selectedFeature = .connection
        } else if tab == .settings {
            navigation.selectedFeature = .settings
            navigation.selectedTab = .settings
        } else {
            navigation.selectedFeature = .limits
            navigation.selectedTab = .status
        }
        dockVisibilityController.prepareToShowMainWindow()
        NSApplication.shared.activate(ignoringOtherApps: true)
        openWindow(id: "main")
    }

    private func openSnapInsert() {
        navigation.selectedFeature = .snapinsert
        dockVisibilityController.prepareToShowMainWindow()
        NSApplication.shared.activate(ignoringOtherApps: true)
        openWindow(id: "main")
    }
}

private struct MacSnapInsertMenuStatus: View {
    let receiver: MacReceiver
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "camera.on.rectangle")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 20)
                    .accessibilityHidden(true)
                HStack {
                        Text("SnapInsert")
                            .font(.headline)
                        Spacer(minLength: 8)
                        Text(statusTitle)
                            .font(.body)
                            .foregroundStyle(statusColor)
                }
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .background(
                .quaternary.opacity(0.45),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .help("\(receiver.status)\n打开 SnapInsert 接收与配对页面")
        .accessibilityLabel("SnapInsert，\(statusTitle)")
        .accessibilityValue(receiver.status)
        .accessibilityHint("打开主窗口的 SnapInsert 页面")
    }

    private var statusTitle: String {
        if receiver.requiresInvitation { return "需要授权" }
        if receiver.isListening { return "已连接" }
        if receiver.isReceivingEnabled { return "等待连接" }
        return "已暂停"
    }

    private var statusColor: Color {
        if receiver.requiresInvitation { return .orange }
        if receiver.isListening { return .green }
        if receiver.isReceivingEnabled { return .orange }
        return .secondary
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
                Text("Codex")
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
                .font(menuStyle ? .headline : .title2.weight(.semibold))

            Spacer(minLength: 12)

            Text(balance)
                .font(menuStyle ? .title2.monospacedDigit() : .largeTitle.monospacedDigit())
                .fontWeight(menuStyle ? .regular : .bold)
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
    MacOverviewView(store: MacStatusStore(previewSnapshot: .preview))
}
