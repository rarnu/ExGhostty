import Foundation
import AppKit

/// 通过 GitHub API 检查是否有新版本发布（轻量检查，仅提示并跳转下载页）。
final class GitHubUpdateChecker {
    static let shared = GitHubUpdateChecker()

    private let apiURL = URL(string: "https://api.github.com/repos/rarnu/ExGhostty/releases/latest")!

    enum CheckResult {
        /// 有新版本：tag 名称与 Release 页面地址。
        case updateAvailable(version: String, url: URL)
        /// 当前已是最新版本。
        case upToDate
        /// 仓库还没有任何 Release。
        case noReleases
    }

    private struct Release: Decodable {
        let tagName: String
        let htmlURL: URL
        let name: String?

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case name
        }
    }

    private init() {}

    /// 当前应用版本（CFBundleShortVersionString，例如 "0.1"）。
    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// 执行一次检查。网络错误会抛出异常；仓库无 Release 返回 `.noReleases`。
    func check() async throws -> CheckResult {
        var request = URLRequest(url: apiURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        if httpResponse.statusCode == 404 {
            return .noReleases
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw URLError(.badServerResponse)
        }

        let release = try JSONDecoder().decode(Release.self, from: data)
        let remoteVersion = release.tagName
        if compareVersions(remoteVersion, currentVersion) == .orderedDescending {
            return .updateAvailable(version: remoteVersion, url: release.htmlURL)
        }
        return .upToDate
    }

    /// 语义化版本比较（忽略 v/V 前缀，按数字段比较；例如 0.2 > 0.10 为假、0.10 > 0.2 为真）。
    func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = lhs.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        let right = rhs.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "vV"))

        let leftParts = left.split(separator: ".").map { Int($0) ?? 0 }
        let rightParts = right.split(separator: ".").map { Int($0) ?? 0 }
        let count = max(leftParts.count, rightParts.count)

        for i in 0..<count {
            let l = i < leftParts.count ? leftParts[i] : 0
            let r = i < rightParts.count ? rightParts[i] : 0
            if l > r { return .orderedDescending }
            if l < r { return .orderedAscending }
        }
        return .orderedSame
    }

    /// 手动检查（菜单触发）：所有结果都会弹窗告知用户。
    @MainActor func checkManually() {
        Task {
            do {
                let result = try await check()
                await MainActor.run {
                    switch result {
                    case .updateAvailable(let version, let url):
                        showUpdateAlert(version: version, url: url)
                    case .upToDate:
                        showInfoAlert(
                            title: "No Update Available".localized,
                            message: String(format: "You are running the latest version (%@).".localized, currentVersion)
                        )
                    case .noReleases:
                        showInfoAlert(
                            title: "No Releases Found".localized,
                            message: "The repository has not published any releases yet.".localized
                        )
                    }
                }
            } catch {
                await MainActor.run {
                    showInfoAlert(
                        title: "Update Check Failed".localized,
                        message: error.localizedDescription
                    )
                }
            }
        }
    }

    /// 后台静默检查（启动时触发）：仅在发现新版本时弹窗，其余情况不打扰用户。
    func checkInBackground() {
        Task {
            guard let result = try? await check(),
                  case .updateAvailable(let version, let url) = result else { return }
            await MainActor.run {
                showUpdateAlert(version: version, url: url)
            }
        }
    }

    // MARK: - Alerts

    @MainActor private func showUpdateAlert(version: String, url: URL) {
        let alert = NSAlert()
        alert.messageText = String(format: "New Version Available: %@".localized, version)
        alert.informativeText = String(
            format: "A new version of ExGhostty is available. You are running %@.".localized,
            currentVersion
        )
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Download".localized)
        alert.addButton(withTitle: "Later".localized)
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(url)
        }
    }

    @MainActor private func showInfoAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK".localized)
        alert.runModal()
    }
}
