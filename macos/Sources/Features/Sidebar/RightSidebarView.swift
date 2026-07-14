import AppKit
import SwiftUI

/// 右侧栏支持的功能项。
enum RightSidebarFeature: String, CaseIterable, Identifiable {
    case sftp
    case sessionReuse
    case systemMonitor
    case codeSnippet
    case aiAssistant

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sftp:           return "SFTP"
        case .sessionReuse:   return "会话复用"
        case .systemMonitor:  return "系统监控"
        case .codeSnippet:    return "代码片段"
        case .aiAssistant:    return "AI 助手"
        }
    }

    var icon: String {
        switch self {
        case .sftp:           return "folder"
        case .sessionReuse:   return "doc.on.doc"
        case .systemMonitor:  return "cpu"
        case .codeSnippet:    return "number"
        case .aiAssistant:    return "sparkles"
        }
    }
}

/// 右侧栏图标条，始终显示功能按钮；SFTP 仅在当前终端为 SSH 连接时显示。
struct RightSidebarView: View {
    let selectedFeature: RightSidebarFeature?
    let terminalController: TerminalController?
    var onSelectFeature: ((RightSidebarFeature) -> Void)?

    private var visibleFeatures: [RightSidebarFeature] {
        guard terminalController?.sshConnection == nil else {
            return RightSidebarFeature.allCases
        }
        return RightSidebarFeature.allCases.filter { $0 != .sftp }
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
