import SwiftUI

struct MacSettingsView: View {
    let store: MacStatusStore
    let updateChecker: MacUpdateChecker
    @Bindable var snapReceiver: MacReceiver
    let openPairing: () -> Void
    @AppStorage(MenuBarDisplayStyle.storageKey) private var displayStyle = MenuBarDisplayStyle.progressBar
    @State private var confirmingResetPhotos = false
    @State private var showingPrivacy = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BuddyStyle.contentSpacing) {
                header
                menuBarCard
                snapInsertCard
                if store.usesSandboxedFolderAccess {
                    dataAccessCard
                }
                cloudCard
                updateCard
                aboutCard
            }
            .padding(BuddyStyle.pagePadding)
            .frame(maxWidth: BuddyStyle.contentWidth)
            .frame(maxWidth: .infinity)
        }
        .font(BuddyMacTypography.body)
        .background { BuddyPageBackground() }
        .navigationTitle("设置")
        .onAppear { snapReceiver.refreshAccessibility() }
        .confirmationDialog("重置 SnapInsert 连接？", isPresented: $confirmingResetPhotos, titleVisibility: .visible) {
            Button("重置照片连接", role: .destructive) {
                snapReceiver.rotatePairing()
                openPairing()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("当前照片连接将断开，需要重新扫描统一二维码。")
        }
        .sheet(isPresented: $showingPrivacy) {
            NavigationStack {
                BuddyPrivacyView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("完成") { showingPrivacy = false }
                        }
                    }
            }
            .frame(minWidth: 500, idealWidth: 600, minHeight: 480, idealHeight: 620)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "gearshape")
                .font(BuddyMacTypography.pageTitle)
                .foregroundStyle(.primary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("设置")
                    .font(BuddyMacTypography.pageTitle)
                Text("管理菜单栏、照片接收与应用偏好。")
                    .font(BuddyMacTypography.detail)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private var menuBarCard: some View {
        MacSettingsCard("菜单栏", systemImage: "menubar.rectangle") {
            HStack(spacing: 18) {
                Text("额度样式")
                Spacer(minLength: 0)
                Picker("额度样式", selection: $displayStyle) {
                    ForEach(MenuBarDisplayStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 160)
            }
        }
    }

    private var snapInsertCard: some View {
        MacSettingsCard("SnapInsert", systemImage: "camera.on.rectangle") {
            switchRow("接收照片", isOn: Binding(
                get: { snapReceiver.isReceivingEnabled },
                set: { enabled in
                    if enabled != snapReceiver.isReceivingEnabled {
                        snapReceiver.toggleReceiving()
                    }
                }
            ))
            Divider()
            switchRow("自动粘贴", isOn: $snapReceiver.automaticallyPaste)
            Divider()
            valueRow("辅助功能", value: snapReceiver.accessibilityGranted ? "已授权" : "未授权")
            if !snapReceiver.accessibilityGranted {
                Button("打开辅助功能设置") { snapReceiver.requestAccessibility() }
                    .buddySecondaryButtonStyle()
            }
            Divider()
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    pairingButton
                    resetButton
                }
                VStack(alignment: .leading, spacing: 12) {
                    pairingButton
                    resetButton
                }
            }
        }
    }

    private var pairingButton: some View {
        Button("显示配对二维码", systemImage: "qrcode", action: openPairing)
            .buddySecondaryButtonStyle()
    }

    private var resetButton: some View {
        Button("重置照片连接…", role: .destructive) { confirmingResetPhotos = true }
            .buddySecondaryButtonStyle()
    }

    private var dataAccessCard: some View {
        MacSettingsCard("Codex 数据访问", systemImage: "folder") {
            valueRow("已授权文件夹", value: store.authorizedCodexFolderPath ?? "尚未选择")
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    folderButtons
                }
                VStack(alignment: .leading, spacing: 12) {
                    folderButtons
                }
            }
            Text("仅访问你选择的文件夹。")
                .font(BuddyMacTypography.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var folderButtons: some View {
        Button("选择 .codex 文件夹", systemImage: "folder.badge.plus") {
            store.chooseCodexFolder()
        }
        .buddySecondaryButtonStyle()
        if store.authorizedCodexFolderPath != nil {
            Button("移除授权", systemImage: "xmark.circle", role: .destructive) {
                store.clearCodexFolderAuthorization()
            }
            .buddySecondaryButtonStyle()
        }
    }

    private var cloudCard: some View {
        MacSettingsCard("iCloud 同步", systemImage: "icloud") {
            CodexCloudStatusView(status: store.cloudStatus)
                .padding(.horizontal, -16)
        }
    }

    private var updateCard: some View {
        MacSettingsCard("软件更新", systemImage: "arrow.triangle.2.circlepath") {
            valueRow("当前版本", value: updateChecker.installedVersionDescription)
            Divider()
            if updateChecker.usesMacAppStoreUpdates {
                Text("通过 Mac App Store 更新。")
                    .foregroundStyle(.secondary)
            } else {
                MacSettingsUpdateStatusView(updateChecker: updateChecker)
            }
        }
    }

    private var aboutCard: some View {
        MacSettingsCard("关于", systemImage: "info.circle") {
            Button { showingPrivacy = true } label: {
                Label("隐私政策", systemImage: "hand.raised")
            }
            .buddySecondaryButtonStyle()
            Divider()
            Link(destination: BuddyLinks.termsURL) {
                Label("使用条款", systemImage: "doc.text")
            }
            Divider()
            Link(destination: BuddyLinks.supportURL) {
                Label("支持与反馈", systemImage: "bubble.left.and.bubble.right")
            }
        }
    }

    private func switchRow(_ title: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 18) {
            Text(title)
                .accessibilityHidden(true)
            Spacer(minLength: 12)
            Toggle(title, isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .accessibilityLabel(title)
        }
    }

    private func valueRow(_ title: String, value: String) -> some View {
        HStack(spacing: 18) {
            Text(title)
                .fixedSize()
            Spacer(minLength: 12)
            Text(value)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct MacSettingsCard<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: Content

    init(_ title: String, systemImage: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: systemImage)
                .font(BuddyMacTypography.cardTitle)
                .foregroundStyle(.primary)
            content
        }
        .padding(BuddyStyle.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .buddyCardSurface()
    }
}

private struct MacSettingsUpdateStatusView: View {
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
            ViewThatFits(in: .horizontal) {
                HStack {
                    upToDateLabel
                    Spacer(minLength: 12)
                    checkButton
                }
                VStack(alignment: .leading, spacing: 12) {
                    upToDateLabel
                    checkButton
                }
            }
        case .updateAvailable(let release):
            VStack(alignment: .leading, spacing: 9) {
                Label("可更新到 \(release.displayVersion)", systemImage: "arrow.down.circle.fill")
                    .foregroundStyle(.blue)
                if let body = release.body, !body.isEmpty {
                    Text(body)
                        .font(BuddyMacTypography.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                HStack(spacing: 12) {
                    Button("下载更新") { updateChecker.openDownload(for: release) }
                        .buddyPrimaryButtonStyle()
                    Button("重新检查") {
                        Task { await updateChecker.checkForUpdates() }
                    }
                    .buddySecondaryButtonStyle()
                }
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                Label("检查更新失败", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(message)
                    .font(BuddyMacTypography.caption)
                    .foregroundStyle(.secondary)
                checkButton
            }
        }
    }

    private var upToDateLabel: some View {
        Label("已是最新版本", systemImage: "checkmark.circle.fill")
            .foregroundStyle(.green)
    }

    private var checkButton: some View {
        Button("检查更新", systemImage: "arrow.triangle.2.circlepath") {
            Task { await updateChecker.checkForUpdates() }
        }
        .buddySecondaryButtonStyle()
    }
}
