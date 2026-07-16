import AppKit
import SwiftUI

/// 代码片段功能面板。
struct CodeSnippetPanelView: View {
    @ObservedObject private var store = CodeSnippetStore.shared
    let terminalController: TerminalController?

    @State private var deleteCategoryConfirmation: CodeSnippetCategory? = nil
    @State private var deleteSnippetConfirmation: CodeSnippet? = nil

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            listView
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .alert(item: $deleteCategoryConfirmation) { category in
            Alert(
                title: Text("删除分类"),
                message: Text("确定要删除分类 \"\(category.name)\" 吗？该分类下的代码片段将移动到默认分类。"),
                primaryButton: .destructive(Text("删除")) {
                    store.removeCategory(category.id)
                },
                secondaryButton: .cancel(Text("取消"))
            )
        }
        .alert(item: $deleteSnippetConfirmation) { snippet in
            Alert(
                title: Text("删除代码片段"),
                message: Text("确定要删除代码片段 \"\(snippet.name)\" 吗？此操作不可撤销。"),
                primaryButton: .destructive(Text("删除")) {
                    store.removeSnippet(snippet.id)
                },
                secondaryButton: .cancel(Text("取消"))
            )
        }
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
            Button("修改分类名称") {
                showEditCategory(category)
            }
            if category.id != store.defaultCategory.id {
                Divider()
                Button(role: .destructive) {
                    deleteCategoryConfirmation = category
                } label: {
                    Text("删除分类")
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
            Button(role: .destructive) {
                deleteSnippetConfirmation = snippet
            } label: {
                Text("删除代码片段")
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
        surface.sendText(snippet.content)
        surface.sendKeyEvent(Ghostty.Input.KeyEvent(key: .enter, action: .press, text: "\r"))
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
        let controller = CodeSnippetCategoryWindowController(
            category: category,
            config: config(),
            parentWindow: parent,
            onSave: { saved in
                if category == nil {
                    self.store.addCategory(saved)
                } else {
                    self.store.updateCategory(saved)
                }
            },
            onDismiss: {}
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
