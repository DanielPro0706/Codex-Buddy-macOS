import SwiftUI

enum BuddyStyle {
    #if os(macOS)
    static let pagePadding: CGFloat = 28
    #else
    static let pagePadding: CGFloat = 16
    #endif
    static let contentSpacing: CGFloat = 18
    static let cardPadding: CGFloat = 18
    static let cornerRadius: CGFloat = 24
    static let contentWidth: CGFloat = 680
}

struct BuddyPageBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            if colorScheme == .light {
                LinearGradient(colors: [.indigo.opacity(0.16), .white],
                               startPoint: .top, endPoint: .bottom)
            } else {
                Color.black
                LinearGradient(colors: [.indigo.opacity(0.20), .blue.opacity(0.07), .clear],
                               startPoint: .topTrailing, endPoint: .bottomLeading)
                RadialGradient(colors: [.cyan.opacity(0.12), .clear], center: .bottomLeading,
                               startRadius: 20, endRadius: 420)
            }
        }
        .ignoresSafeArea()
    }
}

extension View {
    @ViewBuilder
    func buddyCardSurface() -> some View {
        if #available(iOS 26, macOS 26, *) {
            glassEffect(.regular, in: RoundedRectangle(cornerRadius: BuddyStyle.cornerRadius,
                                                       style: .continuous))
        } else {
            background(.regularMaterial,
                       in: RoundedRectangle(cornerRadius: BuddyStyle.cornerRadius, style: .continuous))
        }
    }
}
