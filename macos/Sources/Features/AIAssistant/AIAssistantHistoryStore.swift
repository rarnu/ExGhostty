import Foundation
import Combine

/// 负责持久化与查询 AI 对话历史。
@MainActor
final class AIAssistantHistoryStore: ObservableObject {
    static let shared = AIAssistantHistoryStore()

    private static let storageKey = "ai-assistant-history"
    private static let maxConversations = 100

    @Published var conversations: [AIConversation] = []

    private var saveTask: Task<Void, Never>?

    private init() {
        load()
    }

    /// 加载所有历史对话。
    private func load() {
        guard let data = UserDefaults.ghostty.data(forKey: Self.storageKey) else { return }
        do {
            conversations = try JSONDecoder().decode([AIConversation].self, from: data)
        } catch {
            conversations = []
        }
    }

    /// 异步保存历史对话，避免频繁写入。
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            self?.saveImmediately()
        }
    }

    private func saveImmediately() {
        do {
            let data = try JSONEncoder().encode(conversations)
            UserDefaults.ghostty.set(data, forKey: Self.storageKey)
        } catch {
            // 持久化失败时静默处理
        }
    }

    /// 创建一条新对话并返回。
    @discardableResult
    func createConversation() -> AIConversation {
        let conversation = AIConversation(title: "New Conversation".localized)
        conversations.insert(conversation, at: 0)
        enforceLimit()
        scheduleSave()
        return conversation
    }

    /// 保存或更新一条对话；若已存在则替换，否则插入到最前面。
    func save(_ conversation: AIConversation) {
        if let index = conversations.firstIndex(where: { $0.id == conversation.id }) {
            conversations[index] = conversation
        } else {
            conversations.insert(conversation, at: 0)
        }
        enforceLimit()
        scheduleSave()
    }

    /// 根据 ID 查找对话。
    func conversation(id: UUID) -> AIConversation? {
        conversations.first { $0.id == id }
    }

    /// 删除指定对话。
    func delete(id: UUID) {
        conversations.removeAll { $0.id == id }
        scheduleSave()
    }

    /// 删除全部历史。
    func deleteAll() {
        conversations.removeAll()
        scheduleSave()
    }

    private func enforceLimit() {
        guard conversations.count > Self.maxConversations else { return }
        conversations = Array(conversations.prefix(Self.maxConversations))
    }
}
