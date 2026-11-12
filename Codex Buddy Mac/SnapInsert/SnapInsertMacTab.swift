import AppKit
import SwiftUI

struct SnapInsertMacTab: View {
    @Bindable var receiver: MacReceiver
    let openPairing: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BuddyStyle.contentSpacing) {
                header
                statusCard
                pairingCard
                if receiver.latestPreview != nil || receiver.lastReceipt != nil {
                    VStack(alignment: .leading, spacing: 14) {
                        if let preview = receiver.latestPreview {
                            latestPhoto(preview)
                        }
                        if let receipt = receiver.lastReceipt {
                            Text(receipt)
                                .font(BuddyMacTypography.detail)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(BuddyStyle.cardPadding)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .buddyCardSurface()
                }
            }
            .padding(BuddyStyle.pagePadding)
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
        }
        .font(BuddyMacTypography.body)
        .background { BuddyPageBackground() }
        .navigationTitle("SnapInsert")
        .onAppear { receiver.refreshAccessibility() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "camera.aperture")
                .font(.title2)
                .foregroundStyle(.primary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("SnapInsert")
                    .font(BuddyMacTypography.pageTitle)
                Text("拍一下，即刻接续。")
                    .font(BuddyMacTypography.detail)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: receiver.isListening ? "checkmark.circle.fill" : "pause.circle.fill")
                    .font(.title2)
                    .foregroundStyle(receiver.isListening ? .green : .secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(receiver.status)
                        .font(BuddyMacTypography.cardTitle)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(receiver.computerName)
                        .font(BuddyMacTypography.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)

            if receiver.requiresInvitation {
                Label("请在 iPhone 的设置中验证邀请码或管理 Buddy Pro。", systemImage: "iphone")
                    .font(BuddyMacTypography.detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

        }
        .padding(BuddyStyle.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .buddyCardSurface()
    }

    private var pairingCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("连接 iPhone", systemImage: "iphone")
                .font(BuddyMacTypography.cardTitle)
            Text("与 Limits 共用同一个二维码，一次扫码即可连接。")
                .font(BuddyMacTypography.detail)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Button("配对 iPhone", systemImage: "qrcode.viewfinder", action: openPairing)
                    .buddyPrimaryButtonStyle()
            }
        }
        .padding(BuddyStyle.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .buddyCardSurface()
    }

    private func latestPhoto(_ preview: NSImage) -> some View {
        HStack(spacing: 12) {
            Image(nsImage: preview)
                .resizable()
                .scaledToFill()
                .frame(width: 58, height: 58)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityLabel("最近收到的照片")
            VStack(alignment: .leading, spacing: 6) {
                Text("最近收到")
                    .font(BuddyMacTypography.cardTitle)
                Button("重新复制照片", systemImage: "doc.on.doc") { receiver.copyLatest() }
                    .buttonStyle(.borderless)
            }
            Spacer(minLength: 0)
        }
    }

}
