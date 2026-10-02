import SwiftUI

extension CodexHealthLevel {
    var color: Color {
        switch self {
        case .good: .green
        case .attention: .orange
        case .low: .red
        }
    }
}

struct CodexSymbol: View {
    var size: CGFloat = 36

    var body: some View {
        Image("CodexLogoMac")
            .resizable()
            .renderingMode(.original)
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

struct CodexMonochromeSymbol: View {
    var size: CGFloat = 36

    var body: some View {
        Rectangle()
            .fill(.primary)
            .mask {
                Image("CodexLogoMac")
                    .resizable()
                    .scaledToFit()
                    .luminanceToAlpha()
                    .environment(\.colorScheme, .dark)
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

struct CodexWhiteSymbol: View {
    var size: CGFloat = 36

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.white)
                .mask {
                    Image("CodexLogoMac")
                        .resizable()
                        .scaledToFit()
                }

            CodexPromptCutout()
                .blendMode(.destinationOut)
        }
        .compositingGroup()
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

private struct CodexPromptCutout: View {
    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            let origin = CGPoint(
                x: (geometry.size.width - side) / 2,
                y: (geometry.size.height - side) / 2
            )

            Path { path in
                path.move(to: point(x: 0.343, y: 0.392, side: side, origin: origin))
                path.addLine(to: point(x: 0.405, y: 0.500, side: side, origin: origin))
                path.addLine(to: point(x: 0.343, y: 0.608, side: side, origin: origin))

                path.move(to: point(x: 0.541, y: 0.610, side: side, origin: origin))
                path.addLine(to: point(x: 0.703, y: 0.610, side: side, origin: origin))
            }
            .stroke(
                .white,
                style: StrokeStyle(
                    lineWidth: side * 0.063,
                    lineCap: .round,
                    lineJoin: .round
                )
            )
        }
    }

    private func point(x: CGFloat, y: CGFloat, side: CGFloat, origin: CGPoint) -> CGPoint {
        CGPoint(x: origin.x + side * x, y: origin.y + side * y)
    }
}

struct CodexColoredSymbol: View {
    var size: CGFloat = 36

    var body: some View {
        Image("CodexBuddyGradientMark")
            .resizable()
            .renderingMode(.original)
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

struct CodexUsageCard: View {
    let window: CodexUsageWindow
    var compact = false
    var showsSurface = true
    var prominentHeader = false

    var body: some View {
        let health = CodexHealthLevel(remainingPercent: window.remainingPercent)

        VStack(alignment: .leading, spacing: compact ? 7 : 12) {
            HStack(alignment: .center) {
                Label(window.kind.title, systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                    .font(
                        prominentHeader
                            ? .title2.weight(.semibold)
                            : (compact ? .subheadline.weight(.semibold) : .headline)
                    )
                Spacer()
                Text(window.remainingPercent, format: .percent.scale(1))
                    .font(compact ? .title2.bold() : .largeTitle.bold())
                    .contentTransition(.numericText())
                    .foregroundStyle(health.color)
            }

            CodexQuotaProgressBar(
                progress: window.remainingFraction,
                color: health.color,
                height: compact ? 6 : 8
            )

            if let resetsAt = window.resetsAt {
                CodexRecoveryText(resetsAt: resetsAt)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(compact ? 12 : 18)
        .background {
            if showsSurface {
                RoundedRectangle(cornerRadius: compact ? 16 : 22, style: .continuous)
                    .fill(.regularMaterial)
                    .opacity(compact ? 0.72 : 1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(window.kind.title)剩余百分之\(window.remainingPercent)")
    }
}

struct CodexQuotaProgressBar: View {
    let progress: Double
    let color: Color
    let height: CGFloat

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.secondary.opacity(0.22))
                Capsule()
                    .fill(color)
                    .frame(width: geometry.size.width * min(1, max(0, progress)))
            }
        }
        .id(progress)
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

struct CodexRecoveryText: View {
    let resetsAt: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            Text("\(CodexRecoveryFormat.remaining(until: resetsAt, relativeTo: context.date))后恢复 · \(CodexRecoveryFormat.date(resetsAt))")
        }
    }
}

struct CodexResetCreditsCard: View {
    let summary: CodexResetCreditsSummary
    var compact = false
    var showsSurface = true
    var prominent = false
    var menuStyle = false
    var showsAvailablePrefix = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CodexResetCreditsHeader(
                availableCount: summary.availableCount,
                compact: compact,
                prominent: prominent,
                menuStyle: menuStyle,
                showsAvailablePrefix: showsAvailablePrefix
            )

            VStack(spacing: 0) {
                ForEach(summary.availableCredits) { credit in
                    Divider()
                        .padding(.vertical, menuStyle ? 9 : (compact ? 8 : 11))

                    CodexResetCreditRow(
                        credit: credit,
                        compact: compact,
                        prominent: prominent,
                        menuStyle: menuStyle
                    )
                }
            }
        }
        .padding(.horizontal, menuStyle ? 13 : (compact ? 12 : 18))
        .padding(
            .top,
            menuStyle ? 14 : (prominent || summary.availableCredits.isEmpty ? 18 : 12)
        )
        .padding(.bottom, menuStyle ? 14 : (compact ? 12 : 18))
        .background {
            if menuStyle {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.quaternary.opacity(0.45))
            } else if showsSurface {
                RoundedRectangle(cornerRadius: compact ? 16 : 22, style: .continuous)
                    .fill(.regularMaterial)
                    .opacity(compact ? 0.72 : 1)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

private struct CodexResetCreditsHeader: View {
    let availableCount: Int
    let compact: Bool
    let prominent: Bool
    let menuStyle: Bool
    let showsAvailablePrefix: Bool

    var body: some View {
        HStack(spacing: compact || menuStyle ? 8 : 12) {
            Text("使用限额重置")
                .font(
                    menuStyle
                        ? .system(size: 14, weight: .regular)
                        : prominent
                        ? .title2.weight(.semibold)
                        : (compact ? .headline : .body.weight(.semibold))
                )
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(menuStyle ? 1 : 0.72)
            Spacer(minLength: 8)
            Text(showsAvailablePrefix ? "可用 \(availableCount) 次" : "\(availableCount) 次")
                .font(
                    menuStyle
                        ? .subheadline.weight(.semibold)
                        : prominent
                        ? .headline.weight(.semibold)
                        : (compact ? .headline : .body.weight(.semibold))
                )
                .foregroundStyle(.green)
                .lineLimit(1)
                .minimumScaleFactor(menuStyle ? 1 : 0.75)
                .padding(.horizontal, compact || menuStyle ? 9 : 12)
                .padding(.vertical, compact || menuStyle ? 5 : 7)
                .background(.green.opacity(0.14), in: Capsule())
        }
        .frame(maxWidth: .infinity)
    }
}

private struct CodexResetCreditRow: View {
    let credit: CodexResetCredit
    let compact: Bool
    let prominent: Bool
    let menuStyle: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(credit.displayTitle)
                .font(
                    menuStyle
                        ? .headline
                        : prominent
                        ? .title2.weight(.medium)
                        : (compact ? .headline : .body.weight(.medium))
                )
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Spacer(minLength: 8)
            if let expiresAt = credit.expiresAt {
                Text(CodexResetExpirationFormat.monthDay(expiresAt))
            } else {
                Text("无到期日期")
            }
        }
        .font(menuStyle ? .body : (prominent ? .title2 : (compact ? .headline : .body)))
        .foregroundStyle(.primary)
        .accessibilityElement(children: .combine)
    }
}

struct CodexResetCreditsCompactSummary: View {
    let availableCount: Int
    let nearestExpiration: Date?

    var body: some View {
        HStack(spacing: 5) {
            Text("可用 \(availableCount) 次")
            if let nearestExpiration {
                Text(CodexResetExpirationFormat.monthDay(nearestExpiration))
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct CodexSnapshotHeader: View {
    let planName: String?
    let capturedAt: Date?
    let isStale: Bool

    var body: some View {
        HStack(spacing: 12) {
            CodexSymbol(size: 42)
            VStack(alignment: .leading, spacing: 2) {
                Text("Codex Buddy")
                    .font(.title2.bold())
                Text(planName?.uppercased() ?? "等待数据")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let capturedAt {
                HStack(spacing: 4) {
                    Image(systemName: isStale ? "exclamationmark.triangle.fill" : "clock.arrow.circlepath")
                        .foregroundStyle(isStale ? .orange : .secondary)
                    if isStale {
                        Text("状态可能已过期")
                    } else {
                        Text("更新于")
                    }
                    Text(capturedAt, style: .time)
                        .foregroundStyle(isStale ? .orange : .secondary)
                }
                .font(.caption2)
                .help(isStale ? "状态可能已经过期" : "最后更新时间")
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct CodexCloudStatusView: View {
    let status: CodexCloudSync.OperationStatus
    var compact = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            statusLabel
            Spacer(minLength: 8)
            if case let .synced(date) = status {
                Text(date, style: .time)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .font(compact ? .subheadline : .body)
        .padding(compact ? 12 : 16)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch status {
        case .notChecked:
            Label("尚未检查 iCloud", systemImage: "icloud")
                .foregroundStyle(.secondary)
        case .checking:
            Label("正在连接 iCloud", systemImage: "arrow.trianglehead.2.clockwise.rotate.90")
                .foregroundStyle(.secondary)
        case .synced:
            Label("iCloud 已连接 · 同步成功", systemImage: "checkmark.icloud.fill")
                .foregroundStyle(.green)
        case .connectedWithoutData:
            Label("iCloud 已连接 · 暂无云端状态", systemImage: "icloud")
                .foregroundStyle(.blue)
        case .unavailable(.noAccount):
            Label("未连接 iCloud · 请登录同一 Apple Account", systemImage: "person.crop.circle.badge.exclamationmark")
                .foregroundStyle(.orange)
        case .unavailable(.restricted):
            Label("iCloud 访问受限", systemImage: "lock.icloud")
                .foregroundStyle(.orange)
        case .unavailable(.temporarilyUnavailable):
            Label("iCloud 暂时不可用", systemImage: "icloud.slash")
                .foregroundStyle(.orange)
        case .unavailable(.couldNotDetermine), .unavailable(.unknown):
            Label("无法确认 iCloud 登录状态", systemImage: "questionmark.diamond")
                .foregroundStyle(.orange)
        case .unavailable(.checking):
            Label("正在检查 iCloud", systemImage: "arrow.trianglehead.2.clockwise.rotate.90")
                .foregroundStyle(.secondary)
        case .unavailable(.available):
            Label("iCloud 已连接", systemImage: "icloud.fill")
                .foregroundStyle(.blue)
        case .failed(.network):
            Label("iCloud 网络连接失败，将自动重试", systemImage: "wifi.exclamationmark")
                .foregroundStyle(.orange)
        case .failed(.permission):
            Label("iCloud 容器权限不匹配", systemImage: "lock.trianglebadge.exclamationmark")
                .foregroundStyle(.red)
        case .failed(.configuration):
            Label("iCloud Production 配置未完成", systemImage: "exclamationmark.icloud.fill")
                .foregroundStyle(.red)
        case .failed(.rateLimited):
            Label("iCloud 请求过于频繁，将自动重试", systemImage: "clock.badge.exclamationmark")
                .foregroundStyle(.orange)
        case .failed(.unavailable):
            Label("iCloud 服务不可用，将自动重试", systemImage: "icloud.slash")
                .foregroundStyle(.orange)
        case let .failed(.unknown(message)):
            Label {
                Text("iCloud 同步失败：\(message)")
            } icon: {
                Image(systemName: "exclamationmark.icloud.fill")
            }
            .foregroundStyle(.red)
        }
    }
}
