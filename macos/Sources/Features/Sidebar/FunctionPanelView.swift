import AppKit
import SwiftUI

/// 右侧功能面板内容。
struct FunctionPanelView: View {
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
                placeholder("请先通过 SSH 连接")
            }
        case .portForward:
            PortForwardListView()
        case .sessionReuse:
            SessionReusePanelView(terminalController: terminalController)
        case .codeSnippet:
            CodeSnippetPanelView(terminalController: terminalController)
        case .systemMonitor, .aiAssistant, .none:
            placeholder(feature?.title ?? "")
        }
    }

    private func placeholder(_ title: String) -> some View {
        VStack {
            Spacer()
            Text(title.isEmpty ? "选择右侧功能" : title)
                .font(.system(size: 13))
                .foregroundColor(.secondary)
            Spacer()
        }
    }

    private var topToolbar: some View {
        HStack(spacing: 0) {
            Text(feature?.title ?? "")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.secondary)
            Spacer()
            Button(action: { onClose?() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help("关闭")
        }
        .frame(height: 32)
        .padding(.horizontal, 8)
    }
}
