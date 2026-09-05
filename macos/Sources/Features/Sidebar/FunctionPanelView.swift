import AppKit
import SwiftUI

/// 右侧功能面板内容。
struct FunctionPanelView: View {
    @Environment(\.appTheme) private var appTheme

    let feature: RightSidebarFeature?
    let terminalController: TerminalController?
    var onClose: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            topToolbar
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var content: some View {
        switch feature {
        case .sftp:
            if let connection = terminalController?.sshConnection {
                SFTPPanelView(connection: connection, terminalController: terminalController)
            } else {
                placeholder("Connect via SSH first".localized)
            }
        case .portForward:
            PortForwardListView()
        case .portUsage:
            PortUsagePanelView(terminalController: terminalController)
        case .sessionReuse:
            SessionReusePanelView(terminalController: terminalController)
        case .codeSnippet:
            CodeSnippetPanelView(terminalController: terminalController)
        case .systemMonitor:
            SystemMonitorPanelView(terminalController: terminalController)
        case .docker:
            DockerPanelView(terminalController: terminalController)
        case .aiAssistant:
            AIAssistantPanelView(terminalController: terminalController)
        case .none:
            placeholder(feature?.title ?? "")
        }
    }

    private func placeholder(_ title: String) -> some View {
        VStack {
            Spacer()
            Text(title.isEmpty ? "Choose a feature".localized : title)
                .font(.system(size: 13))
                .foregroundColor(appTheme.secondaryForeground)
            Spacer()
        }
    }

    private var topToolbar: some View {
        HStack(spacing: 0) {
            Text(feature?.title ?? "")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(appTheme.secondaryForeground)
            Spacer()
            Button(action: { onClose?() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(appTheme.secondaryForeground)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help("Close".localized)
        }
        .frame(height: 32)
        // leading 稍大：面板左缘紧贴 split 分隔线，避免标题首字符被分隔线覆盖裁切。
        .padding(.leading, 12)
        .padding(.trailing, 8)
    }
}
