import AppKit
import SwiftUI

struct SnapInsertMacTab: View {
    @Bindable var receiver: MacReceiver
    @State private var showPairing = true
    @State private var showResetConfirmation = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                statusCard
                if receiver.requiresInvitation {
                    Label("请在 iPhone 的 SnapInsert 设置中验证邀请码或管理订阅。", systemImage: "iphone")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                DisclosureGroup("配对 iPhone", isExpanded: $showPairing) {
                    pairingCard
                        .padding(.top, 12)
                }

                Toggle("自动粘贴到当前编辑位置", isOn: $receiver.automaticallyPaste)
                    .toggleStyle(.switch)
                if !receiver.accessibilityGranted {
                    permissionCard
                }

                if let preview = receiver.latestPreview {
                    latestPhoto(preview)
                }

                if let receipt = receiver.lastReceipt {
                    Text(receipt)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }

                Text("拍照前，先在 Mac 上点好插入位置。接收照片会覆盖剪贴板；目标应用需要支持粘贴图片。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()
                footer
            }
            .padding(20)
        }
        .onAppear { receiver.refreshAccessibility() }
        .confirmationDialog("解除所有 iPhone 配对？", isPresented: $showResetConfirmation) {
            Button("解除配对并生成新二维码", role: .destructive) { receiver.rotatePairing() }
            Button("取消", role: .cancel) { }
        } message: {
            Text("当前连接将断开。请用 iPhone 重新扫描二维码，并在 iPhone 上完成授权。")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "camera.aperture")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("SnapInsert")
                    .font(.title2.weight(.semibold))
                Text("拍一下，即刻接续。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var statusCard: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: receiver.isListening ? "checkmark.circle.fill" : "pause.circle.fill")
                .foregroundStyle(receiver.isListening ? .green : .secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(receiver.status)
                    .font(.callout.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                Text(receiver.computerName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }

    private var permissionCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("允许自动粘贴", systemImage: "hand.raised")
                .font(.callout.weight(.medium))
            Text("开启辅助功能权限后，照片会自动粘贴。也可以先接收，再手动按 ⌘V。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("打开辅助功能设置") { receiver.requestAccessibility() }
                .buttonStyle(.bordered)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }

    private var pairingCard: some View {
        VStack(spacing: 10) {
            if let qr = receiver.qrImage {
                Image(nsImage: qr)
                    .resizable()
                    .interpolation(.none)
                    .scaledToFit()
                    .frame(width: 192, height: 192)
                    .padding(12)
                    .background(.white, in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityLabel("使用 iPhone 上 Codex Buddy 的 SnapInsert 扫描此配对二维码")
            } else {
                Label("暂时无法生成配对二维码", systemImage: "exclamationmark.triangle")
                    .font(.callout)
            }
            Text("在 iPhone 上打开 Codex Buddy 的 SnapInsert，扫描此二维码。两端只需联网；照片端到端加密，经阿里云服务器转发。请勿分享配对码。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("解除所有设备配对…", role: .destructive) { showResetConfirmation = true }
                .font(.caption)
                .buttonStyle(.borderless)
        }
        .frame(maxWidth: .infinity)
    }

    private func latestPhoto(_ preview: NSImage) -> some View {
        HStack(spacing: 12) {
            Image(nsImage: preview)
                .resizable()
                .scaledToFill()
                .frame(width: 58, height: 58)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel("最近收到的照片")
            VStack(alignment: .leading, spacing: 6) {
                Text("最近收到")
                    .font(.callout.weight(.medium))
                Button("重新复制照片", systemImage: "doc.on.doc") { receiver.copyLatest() }
                    .buttonStyle(.borderless)
            }
            Spacer()
        }
    }

    private var footer: some View {
        HStack {
            Button(receiver.isReceivingEnabled ? "暂停接收" : "开始接收") { receiver.toggleReceiving() }
            Spacer()
            Text("关闭窗口或切换 Tab 后，仍可继续接收。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .font(.callout)
    }
}
