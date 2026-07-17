import Foundation

/// AI 对话中的消息角色。
enum AIMessageRole: String, Codable, CaseIterable {
    case system
    case user
    case assistant
}

/// AI 对话中的一条消息。
struct AIMessage: Identifiable, Codable, Equatable {
    var id: UUID
    var role: AIMessageRole
    var content: String
    var timestamp: Date

    init(
        id: UUID = UUID(),
        role: AIMessageRole,
        content: String,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
    }
}

/// 一段完整的 AI 对话（历史记录单元）。
struct AIConversation: Identifiable, Codable, Equatable {
    var id: UUID
    var title: String
    var messages: [AIMessage]
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        title: String,
        messages: [AIMessage] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.messages = messages
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// 生成一个简洁的标题：取第一条用户消息的前 20 个字符，若为空则使用默认标题。
    var displayTitle: String {
        if !title.isEmpty && title != "New Conversation".localized {
            return title
        }
        if let firstUser = messages.first(where: { $0.role == .user })?.content.trimmingCharacters(in: .whitespacesAndNewlines),
           !firstUser.isEmpty {
            let prefix = String(firstUser.prefix(20))
            return firstUser.count > 20 ? prefix + "…" : prefix
        }
        return "New Conversation".localized
    }
}
