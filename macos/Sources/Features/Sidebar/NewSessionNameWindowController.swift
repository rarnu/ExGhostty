import AppKit
import SwiftUI
import GhosttyKit

// MARK: - 新建会话命名窗口

/// 新建 tmux / zellij 会话的命名窗口。
/// 标准 macOS 窗口（带三色灯），仅关闭按钮可用，支持 ESC 关闭，
/// 背景透明/磨砂效果与主窗口一致。
final class NewSessionNameWindowController: ModalWindowController {
    private static var activeControllers = NSHashTable<NewSessionNameWindowController>(options: .strongMemory)

    init(
        config: Ghostty.Config,
        type: SessionType,
        parentWindow: NSWindow? = nil,
        onConfirm: @escaping (String) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        let window = NewSessionNameWindow(config: config)
        super.init(window: window, parentWindow: parentWindow)

        Self.activeControllers.add(self)

        let view = NewSessionNameView(
            type: type,
            onConfirm: { [weak self] name in
                self?.close()
                onConfirm(name)
            },
            onCancel: { [weak self] in
                self?.close()
                onDismiss()
            }
        )
        .frame(width: 360)

        let hostingView = NSHostingView(rootView: view)
        hostingView.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(hostingView)

        NSLayoutConstraint.activate([
            hostingView.topAnchor.constraint(equalTo: container.topAnchor),
            hostingView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hostingView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            hostingView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])

        window.contentView = container
        window.title = "新建\(type.displayName)会话"
        window.configureBackgroundBlur(config: config, container: container)
    }

    override func windowWillClose(_ notification: Notification) {
        super.windowWillClose(notification)
        Self.activeControllers.remove(self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}

private final class NewSessionNameWindow: GhosttyPanelWindow {
    init(config: Ghostty.Config) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 160),
            config: config
        )
        self.minSize = NSSize(width: 360, height: 160)
        self.maxSize = NSSize(width: 360, height: 160)
    }
}

// MARK: - SwiftUI 内容

private struct NewSessionNameView: View {
    let type: SessionType
    let onConfirm: (String) -> Void
    let onCancel: () -> Void

    @State private var name: String = ""
    @FocusState private var isNameFocused: Bool

    var body: some View {
        VStack(spacing: 16) {
            Text("新建\(type.displayName)会话")
                .font(.headline)

            TextField("会话名称", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($isNameFocused)
                .onChange(of: name) { newValue in
                    let filtered = newValue.filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
                    if filtered != newValue {
                        name = filtered
                    }
                }
                .onSubmit {
                    confirm()
                }

            HStack(spacing: 12) {
                Button("取消") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("确认") { confirm() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding()
        .frame(width: 360, height: 160)
        .onAppear { isNameFocused = true }
    }

    private func confirm() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onConfirm(trimmed)
    }
}
