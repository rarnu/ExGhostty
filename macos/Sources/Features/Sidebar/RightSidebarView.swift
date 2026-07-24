import AppKit
import SwiftUI

/// 右侧栏支持的功能项。
enum RightSidebarFeature: String, CaseIterable, Identifiable {
    case portForward
    case portUsage
    case sftp
    case sessionReuse
    case systemMonitor
    case codeSnippet
    case aiAssistant

    var id: String { rawValue }

    var title: String {
        switch self {
        case .portForward:    return "Port Forward".localized
        case .portUsage:      return "Port Usage".localized
        case .sftp:           return "SFTP"
        case .sessionReuse:   return "Session Reuse".localized
        case .systemMonitor:  return "System Monitor".localized
        case .codeSnippet:    return "Code Snippets".localized
        case .aiAssistant:    return "AI Assistant".localized
        }
    }

    var icon: String {
        switch self {
        case .portForward:    return "fibrechannel"
        case .portUsage:      return "p.circle"
        case .sftp:           return "folder"
        case .sessionReuse:   return "infinity.circle"
        case .systemMonitor:  return "cpu"
        case .codeSnippet:    return "richtext.page"
        case .aiAssistant:    return "sparkles"
        }
    }
}

/// 右侧栏图标条，始终显示功能按钮；SFTP 仅在当前终端为 SSH 连接时显示；
/// Telnet 连接仅保留 Port Forward，隐藏 SFTP / Port Usage / Session Reuse / System Monitor / Code Snippets / AI Assistant。
struct RightSidebarView: View {
    let selectedFeature: RightSidebarFeature?
    let terminalController: TerminalController?
    var onSelectFeature: ((RightSidebarFeature) -> Void)?

    private var visibleFeatures: [RightSidebarFeature] {
        guard let conn = terminalController?.sshConnection else {
            return RightSidebarFeature.allCases.filter { $0 != .sftp }
        }
        if conn.type == .telnet {
            return [.portForward]
        }
        return RightSidebarFeature.allCases
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(visibleFeatures) { feature in
                Button(action: { onSelectFeature?(feature) }) {
                    Image(systemName: feature.icon)
                        .font(.system(size: 14))
                        .foregroundColor(foregroundColor(for: feature))
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .help(feature.title)
            }
            Spacer()
        }
        .frame(width: 32)
        .frame(maxHeight: .infinity)
    }

    private func foregroundColor(for feature: RightSidebarFeature) -> Color {
        selectedFeature == feature ? Color.accentColor : Color.secondary
    }
}
