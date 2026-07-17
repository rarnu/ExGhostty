import SwiftUI
import AppKit

/// 历史对话列表弹窗视图。
struct AIHistoryListView: View {
    @StateObject private var store = AIAssistantHistoryStore.shared

    var onSelect: (AIConversation) -> Void
    var onDismiss: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            if store.conversations.isEmpty {
                VStack {
                    Spacer()
                    Text("No history conversations".localized)
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(store.conversations) { conversation in
                        Button {
                            onSelect(conversation)
                        } label: {
                            HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(conversation.displayTitle)
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundColor(.primary)
                                        .lineLimit(1)

                                    Text(formatDate(conversation.updatedAt))
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)
                                }

                                Spacer()

                                Text("\(conversation.messages.count) messages".localized)
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(role: .destructive) {
                                store.delete(id: conversation.id)
                            } label: {
                                Label {
                                    Text("Delete".localized)
                                        .foregroundColor(.red)
                                } icon: {
                                    Image(systemName: "trash")
                                        .foregroundColor(.red)
                                }
                            }

                            Divider()

                            Button(role: .destructive) {
                                clearAllWithConfirmation()
                            } label: {
                                Label {
                                    Text("Clear All".localized)
                                        .foregroundColor(.red)
                                } icon: {
                                    Image(systemName: "trash")
                                        .foregroundColor(.red)
                                }
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .frame(minWidth: 360, minHeight: 400)
        .background(Color.clear)
    }

    private func clearAllWithConfirmation() {
        let alert = NSAlert()
        alert.messageText = "Clear All History?".localized
        alert.informativeText = "This will delete all saved AI conversations. This action cannot be undone.".localized
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Clear".localized)
        alert.addButton(withTitle: "Cancel".localized)
        alert.buttons.first?.hasDestructiveAction = true
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            store.deleteAll()
        }
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
