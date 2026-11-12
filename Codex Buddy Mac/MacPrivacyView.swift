import SwiftUI

struct MacPrivacyView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: BuddyStyle.contentSpacing) {
            Label("隐私政策", systemImage: "hand.raised")
                .font(BuddyMacTypography.pageTitle)
                .foregroundStyle(.primary)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 14) {
                summary("额度同步", icon: "gauge.with.dots.needle.67percent",
                        text: "本机保存最近额度；iCloud 与推送服务保存最新快照，推送服务另存设备推送路由。")
                Divider().padding(.leading, 32)
                summary("照片传输", icon: "camera.on.rectangle",
                        text: "照片端到端加密；中转仅在内存转发密文，不写入磁盘。Mac 剪贴板和目标应用可能保留图片。")
                Divider().padding(.leading, 32)
                summary("账户与订阅", icon: "person.crop.circle",
                        text: "服务端保存账户摘要、月用量和订阅关联记录，用于校验额度与权益。授权和订阅请在 iPhone 设置中管理。")
            }
            .padding(BuddyStyle.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .buddyCardSurface()

            HStack(spacing: 10) {
                Link(destination: BuddyLinks.privacyURL) {
                    Label("完整隐私政策", systemImage: "arrow.up.right.square")
                }
                .buddySecondaryButtonStyle()
                Link(destination: BuddyLinks.supportURL) {
                    Label("联系开发者", systemImage: "bubble.left.and.bubble.right")
                }
                .buddySecondaryButtonStyle()
                Spacer(minLength: 12)
                Button("完成") { dismiss() }
                    .buddyPrimaryButtonStyle()
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.regular)
        }
        .padding(24)
        .font(BuddyMacTypography.body)
        .background { BuddyPageBackground() }
        .frame(width: 540)
        .fixedSize(horizontal: false, vertical: true)
        .presentationSizing(.fitted)
        .onExitCommand { dismiss() }
    }

    private func summary(_ title: String, icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(BuddyMacTypography.cardTitle)
                .foregroundStyle(.primary)
                .frame(width: 20, height: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(BuddyMacTypography.cardTitle)
                Text(text)
                    .font(BuddyMacTypography.detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
