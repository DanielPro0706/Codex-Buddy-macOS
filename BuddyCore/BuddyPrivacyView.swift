import SwiftUI

enum BuddyLinks {
    static let sourceURL = URL(string: "https://github.com/DanielPro0706/Codex-Buddy-macOS")!
    static let privacyURL = URL(string: "https://github.com/DanielPro0706/Codex-Buddy-macOS/blob/main/docs/PRIVACY.md")!
    static let termsURL = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
    static let supportURL = URL(string: "https://github.com/DanielPro0706/Codex-Buddy-macOS/issues")!
}

struct BuddyPrivacyView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BuddyStyle.contentSpacing) {
                VStack(alignment: .leading, spacing: 20) {
                    item("额度同步", icon: "gauge.with.dots.needle.67percent",
                         text: "读取本机 Codex 额度，通过 iCloud 和推送服务同步。开发者服务保存快照与推送路由。")
                    item("照片传输", icon: "camera.on.rectangle",
                         text: "照片端到端加密，中转不保存照片。Mac 剪贴板和目标应用可能保留收到的图片。")
                    item("账户与订阅", icon: "person.crop.circle",
                         text: "服务保存账户标识、月用量及订阅状态，用于校验额度和权益。")
                    item("CloudSpace", icon: "icloud",
                         text: "文件由你选择的工作区处理，访问密钥保存在本机钥匙串。")
                }
                .padding(BuddyStyle.cardPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .buddyCardSurface()

                Link(destination: BuddyLinks.privacyURL) {
                    Label("查看完整隐私政策", systemImage: "hand.raised")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Link(destination: BuddyLinks.supportURL) {
                    Label("联系开发者", systemImage: "bubble.left.and.bubble.right")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
            .padding(BuddyStyle.pagePadding)
            .frame(maxWidth: BuddyStyle.contentWidth)
            .frame(maxWidth: .infinity)
        }
        .background { BuddyPageBackground() }
        .navigationTitle("隐私政策")
    }

    private func item(_ title: String, icon: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon).font(.headline)
            Text(text).font(.body).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
