import AppKit
import SwiftUI
import GhosttyKit

// MARK: - 代码片段编辑窗口

/// 弹出代码片段创建/编辑窗口（标准 macOS 模态窗口，带三色灯，仅关闭可用）。
func presentCodeSnippetEditWindow(
    snippet: CodeSnippet?,
    config: Ghostty.Config?,
    on parent: NSWindow,
    onSave: @escaping (CodeSnippet) -> Void,
    onDismiss: @escaping () -> Void
) {
    let controller = CodeSnippetEditorWindowController(
        snippet: snippet,
        config: config,
        parentWindow: parent,
        onSave: onSave,
        onDismiss: onDismiss
    )
    controller.showModal()
}

/// 新增/修改代码片段的标准 macOS 模态窗口。
final class CodeSnippetEditorWindowController: ModalWindowController {
    private static var activeControllers = NSHashTable<CodeSnippetEditorWindowController>(options: .strongMemory)

    private let onSave: (CodeSnippet) -> Void
    private let onDismiss: () -> Void

    init(
        snippet: CodeSnippet? = nil,
        config: Ghostty.Config?,
        parentWindow: NSWindow? = nil,
        onSave: @escaping (CodeSnippet) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.onSave = onSave
        self.onDismiss = onDismiss

        let title = snippet == nil ? "New Snippet".localized : "Edit Snippet".localized
        let window = CodeSnippetEditorWindow(config: config)
        window.title = title

        super.init(window: window, parentWindow: parentWindow)
        Self.activeControllers.add(self)

        let view = CodeSnippetEditorView(
            snippet: snippet,
            onSave: { [weak self] saved in
                self?.onSave(saved)
                self?.close()
            },
            onDismiss: { [weak self] in
                self?.close()
            }
        )
        .frame(width: 560)

        embed(view: view, in: window, config: config)
    }

    override func windowWillClose(_ notification: Notification) {
        super.windowWillClose(notification)
        Self.activeControllers.remove(self)
        onDismiss()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}

private final class CodeSnippetEditorWindow: GhosttyPanelWindow {
    init(config: Ghostty.Config?) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 600),
            config: config
        )
        self.minSize = NSSize(width: 520, height: 520)
    }
}

private struct CodeSnippetEditorView: View {
    @ObservedObject private var store = CodeSnippetStore.shared
    @State private var draft: CodeSnippet
    private let isNew: Bool
    private let onSave: (CodeSnippet) -> Void
    private let onDismiss: () -> Void

    @FocusState private var isNameFocused: Bool

    init(
        snippet: CodeSnippet?,
        onSave: @escaping (CodeSnippet) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        let initial = snippet ?? CodeSnippet(
            name: "",
            type: .shell,
            content: "",
            categoryID: CodeSnippetStore.shared.defaultCategory.id
        )
        self._draft = State(initialValue: initial)
        self.isNew = snippet == nil
        self.onSave = onSave
        self.onDismiss = onDismiss
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    nameField
                    typePicker
                    categoryPicker
                    codeEditor
                }
                .padding(20)
            }

            Divider()

            HStack(spacing: 12) {
                Spacer()
                Button("Cancel".localized) { onDismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save".localized) {
                    onSave(draft)
                    onDismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!draft.isValid)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 560)
        .background(Color.clear)
        .onAppear {
            isNameFocused = true
        }
    }

    private var nameField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Name".localized)
                .font(.system(size: 13, weight: .medium))
            TextField("e.g. Clear Logs".localized, text: $draft.name)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13))
                .focused($isNameFocused)
        }
    }

    private var typePicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Type".localized)
                .font(.system(size: 13, weight: .medium))
            Picker("", selection: $draft.type) {
                ForEach(CodeSnippetType.allCases) { type in
                    Text(type.displayName).tag(type)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    private var categoryPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Category".localized)
                .font(.system(size: 13, weight: .medium))
            Picker("", selection: $draft.categoryID) {
                ForEach(store.categories) { category in
                    Text(category.name).tag(category.id)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
        }
    }

    private var codeEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Code".localized)
                .font(.system(size: 13, weight: .medium))
            CodeEditorView(text: $draft.content, language: draft.type)
                .frame(minHeight: 240)
                .padding(4)
                .background(Color.secondary.opacity(0.08))
                .cornerRadius(6)
        }
    }
}

// MARK: - 辅助

private func embed(view: some View, in window: NSWindow, config: Ghostty.Config?) {
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
    window.configureBackgroundBlur(config: config, container: container)
}
