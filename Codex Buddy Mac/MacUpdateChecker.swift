import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class MacUpdateChecker {
    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case updateAvailable(GitHubRelease)
        case failed(String)
    }

    /// The public GitHub Release is the single source of truth for web-distributed builds.
    private static let releasesURL = URL(string: "https://api.github.com/repos/DanielPro0706/Codex-Buddy-macOS/releases/latest")!
    private static let macDMGAssetName = "Codex-Buddy-Mac.dmg"

    private(set) var state: State = .idle
    private var automaticCheckTask: Task<Void, Never>?

    var usesMacAppStoreUpdates: Bool { CodexFolderAccess.isSandboxed }

    var installedVersionDescription: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "版本 \(version)（\(build)）"
    }

    func startAutomaticCheck() {
        guard !usesMacAppStoreUpdates, automaticCheckTask == nil else { return }
        automaticCheckTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await self?.checkForUpdates()
        }
    }

    func checkForUpdates() async {
        guard !usesMacAppStoreUpdates, state != .checking else { return }
        state = .checking

        do {
            var request = URLRequest(url: Self.releasesURL)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("Codex-Buddy-Mac", forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 12

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse,
                  (200 ..< 300).contains(response.statusCode) else {
                throw UpdateError.releaseUnavailable
            }

            let release = try JSONDecoder.github.decode(GitHubRelease.self, from: data)
            guard let downloadURL = release.assets.first(where: { $0.name == Self.macDMGAssetName })?.browserDownloadURL else {
                throw UpdateError.dmgMissing
            }

            let availableRelease = GitHubRelease(
                tagName: release.tagName,
                name: release.name,
                body: release.body,
                publishedAt: release.publishedAt,
                assets: [GitHubRelease.Asset(name: Self.macDMGAssetName, browserDownloadURL: downloadURL)]
            )

            state = isNewer(availableRelease.version, than: installedVersion)
                ? .updateAvailable(availableRelease)
                : .upToDate
        } catch is CancellationError {
            state = .idle
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func openDownload(for release: GitHubRelease) {
        guard !usesMacAppStoreUpdates, let url = release.assets.first?.browserDownloadURL else { return }
        NSWorkspace.shared.open(url)
    }

    private var installedVersion: Version {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return Version(version: version, build: build)
    }

    private func isNewer(_ candidate: Version, than installed: Version) -> Bool {
        candidate > installed
    }
}

struct GitHubRelease: Decodable, Equatable {
    struct Asset: Decodable, Equatable {
        let name: String
        let browserDownloadURL: URL

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }

    let tagName: String
    let name: String?
    let body: String?
    let publishedAt: Date?
    let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case body
        case publishedAt = "published_at"
        case assets
    }

    var version: Version {
        Version(version: tagName, build: nil)
    }

    var displayVersion: String {
        tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
    }
}

struct Version: Comparable, Equatable {
    private let components: [Int]
    private let build: Int

    init(version: String, build: String?) {
        let normalizedVersion = version.hasPrefix("v") ? String(version.dropFirst()) : version
        components = normalizedVersion
            .split(separator: ".")
            .map { Int($0) ?? 0 }
        self.build = Int(build ?? "0") ?? 0
    }

    static func < (lhs: Version, rhs: Version) -> Bool {
        let componentCount = max(lhs.components.count, rhs.components.count)
        for index in 0 ..< componentCount {
            let left = lhs.components.indices.contains(index) ? lhs.components[index] : 0
            let right = rhs.components.indices.contains(index) ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return lhs.build < rhs.build
    }
}

private enum UpdateError: LocalizedError {
    case releaseUnavailable
    case dmgMissing

    var errorDescription: String? {
        switch self {
        case .releaseUnavailable:
            "暂时无法获取更新信息。"
        case .dmgMissing:
            "最新版本尚未提供 macOS DMG。"
        }
    }
}

private extension JSONDecoder {
    static let github: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
