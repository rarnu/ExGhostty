import AppKit
import SwiftUI
import GhosttyKit

// MARK: - 启动命令模态窗口

/// “查看启动命令”模态窗口：展示重建的 docker run 命令，可滚动、可选择复制，并提供一键复制按钮。
enum DockerRunCommandWindowManager {
    static func show(
        store: DockerService,
        container: DockerContainer,
        config: Ghostty.Config?,
        parentWindow: NSWindow?
    ) {
        let window = GhosttyPanelWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 320),
            config: config
        )
        window.title = L("Start Command: %@", container.names)

        let contentView = DockerRunCommandView(store: store, containerID: container.id) { [weak window] in
            window?.close()
        }
        .frame(minWidth: 600, minHeight: 280)
        // 保持根视图背景透明，让窗口级背景/模糊效果透出来。
        .background(Color.clear)

        let hostingView = NSHostingView(rootView: ThemedRoot { contentView })
        hostingView.translatesAutoresizingMaskIntoConstraints = false

        let containerView = NSView()
        containerView.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(hostingView)

        NSLayoutConstraint.activate([
            hostingView.topAnchor.constraint(equalTo: containerView.topAnchor),
            hostingView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            hostingView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
            hostingView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
        ])

        window.contentView = containerView
        window.configureBackgroundBlur(config: config, container: containerView)

        // 以模态方式显示；showModal 返回（窗口关闭）后 controller 即可释放。
        let controller = ModalWindowController(window: window, parentWindow: parentWindow)
        controller.showModal()
    }
}

// MARK: - 命令内容视图

private struct DockerRunCommandView: View {
    let store: DockerService
    let containerID: String
    let onClose: () -> Void

    @State private var command: String = ""
    @State private var isLoading = true

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if isLoading {
                    ProgressView()
                        .scaleEffect(0.8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        Text(command.isEmpty ? "No output".localized : command)
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                    }
                }
            }

            Divider()

            HStack {
                Button("Copy".localized) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                }
                .controlSize(.regular)
                .disabled(isLoading || command.isEmpty)
                Spacer()
                Button("Close".localized) {
                    onClose()
                }
                .controlSize(.regular)
            }
            .padding()
        }
        .onAppear(perform: load)
    }

    private func load() {
        Task {
            let text = (try? await store.containerRunCommand(id: containerID)) ?? ""
            await MainActor.run {
                command = text
                isLoading = false
            }
        }
    }
}
