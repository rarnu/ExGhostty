import AppKit
import SwiftUI

/// 代码片段功能面板。
struct CodeSnippetPanelView: View {
    @ObservedObject private var store = CodeSnippetStore.shared
    let terminalController: TerminalController?

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            listView
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 工具栏

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button(action: { showAddSnippet() }) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help("新增代码片段")

            Button(action: { showAddCategory() }) {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help("新增分类")

            Spacer()
        }
        .frame(height: 32)
        .padding(.horizontal, 8)
    }

    // MARK: - 列表

    private var listView: some View {
        List {
            ForEach(store.categories) { category in
                Section {
                    let items = store.snippets(for: category.id)
                    if items.isEmpty {
                        Text("暂无代码片段")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(items) { snippet in
                            snippetRow(snippet)
                        }
                    }
                } header: {
                    categoryHeader(category)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private func categoryHeader(_ category: CodeSnippetCategory) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "folder")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .frame(width: 16)

            Text("\(category.name) (\(store.snippets(for: category.id).count))")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.secondary)

            Spacer()
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .contextMenu {
            if category.id != store.defaultCategory.id {
                Button("修改分类名称") {
                    showEditCategory(category)
                }
                Divider()
                Button {
                    showDeleteCategoryConfirmation(category)
                } label: {
                    Text("删除分类")
                        .foregroundColor(.red)
                }
            }
        }
    }

    private func snippetRow(_ snippet: CodeSnippet) -> some View {
        HStack(spacing: 6) {
            Image(systemName: iconName(for: snippet.type))
                .font(.system(size: 11))
                .foregroundColor(.accentColor)
                .frame(width: 16)

            Text(snippet.name)
                .font(.system(size: 14))
                .lineLimit(1)

            Spacer()
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .contextMenu {
            Button("修改代码片段") {
                showEditSnippet(snippet)
            }
            Button {
                showDeleteSnippetConfirmation(snippet)
            } label: {
                Text("删除代码片段")
                    .foregroundColor(.red)
            }
        }
        .onTapGesture(count: 2) {
            executeSnippet(snippet)
        }
    }

    private func iconName(for type: CodeSnippetType) -> String {
        switch type {
        case .shell: return "terminal"
        case .python: return "number"
        }
    }

    // MARK: - 操作

    private func executeSnippet(_ snippet: CodeSnippet) {
        guard let surface = terminalController?.focusedSurface?.surfaceModel else { return }

        let textToSend: String
        switch snippet.type {
        case .shell:
            textToSend = snippet.content
        case .python:
            // 使用 heredoc 将 Python 代码交给 python3 执行，避免被 shell 逐行解析。
            let delimiter = "GHOSTTY_PY_EOF_\(snippet.id.uuidString.replacingOccurrences(of: "-", with: ""))"
            textToSend = "python3 << '\(delimiter)'\n\(snippet.content)\n\(delimiter)"
        }

        surface.sendText(textToSend)
        surface.sendKeyEvent(Ghostty.Input.KeyEvent(key: .enter, action: .press, text: "\r"))
    }

    private func showDeleteCategoryConfirmation(_ category: CodeSnippetCategory) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "删除分类"
            alert.informativeText = "确定要删除分类 \"\(category.name)\" 吗？该分类下的代码片段将移动到默认分类。"
            alert.addButton(withTitle: "删除")
            alert.addButton(withTitle: "取消")
            alert.buttons.first?.hasDestructiveAction = true

            if let win = NSApp.keyWindow {
                alert.beginSheetModal(for: win) { resp in
                    if resp == .alertFirstButtonReturn {
                        self.store.removeCategory(category.id)
                    }
                }
            } else {
                let resp = alert.runModal()
                if resp == .alertFirstButtonReturn {
                    self.store.removeCategory(category.id)
                }
            }
        }
    }

    private func showDeleteSnippetConfirmation(_ snippet: CodeSnippet) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "删除代码片段"
            alert.informativeText = "确定要删除代码片段 \"\(snippet.name)\" 吗？此操作不可撤销。"
            alert.addButton(withTitle: "删除")
            alert.addButton(withTitle: "取消")
            alert.buttons.first?.hasDestructiveAction = true

            if let win = NSApp.keyWindow {
                alert.beginSheetModal(for: win) { resp in
                    if resp == .alertFirstButtonReturn {
                        self.store.removeSnippet(snippet.id)
                    }
                }
            } else {
                let resp = alert.runModal()
                if resp == .alertFirstButtonReturn {
                    self.store.removeSnippet(snippet.id)
                }
            }
        }
    }

    private func showAddCategory() {
        presentCategoryWindow(category: nil)
    }

    private func showEditCategory(_ category: CodeSnippetCategory) {
        presentCategoryWindow(category: category)
    }

    private func showAddSnippet() {
        presentSnippetWindow(snippet: nil)
    }

    private func showEditSnippet(_ snippet: CodeSnippet) {
        presentSnippetWindow(snippet: snippet)
    }

    private func config() -> Ghostty.Config? {
        (NSApp.delegate as? AppDelegate)?.ghostty.config
    }

    private func presentCategoryWindow(category: CodeSnippetCategory?) {
        guard let parent = NSApp.keyWindow else { return }
        let title = category == nil ? "新增分类" : "修改分类"
        let controller = GroupNameWindowController(
            title: title,
            message: "输入分类名称",
            placeholder: "分类名称",
            defaultText: category?.name ?? "",
            confirmTitle: "确认",
            cancelTitle: "取消",
            config: config(),
            parentWindow: parent,
            completion: { name in
                guard let name = name else { return }
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                if let existing = category {
                    var updated = existing
                    updated.name = trimmed
                    self.store.updateCategory(updated)
                } else {
                    self.store.addCategory(CodeSnippetCategory(name: trimmed))
                }
            }
        )
        controller.showModal()
    }

    private func presentSnippetWindow(snippet: CodeSnippet?) {
        DispatchQueue.main.async {
            guard let parent = NSApp.keyWindow else { return }
            presentCodeSnippetEditWindow(
                snippet: snippet,
                config: self.config(),
                on: parent,
                onSave: { saved in
                    if snippet == nil {
                        self.store.addSnippet(saved)
                    } else {
                        self.store.updateSnippet(saved)
                    }
                },
                onDismiss: {}
            )
        }
    }
}
