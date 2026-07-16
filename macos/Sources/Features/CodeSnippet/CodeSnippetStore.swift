import Foundation
import SwiftUI
import Combine

/// 代码片段类型。
enum CodeSnippetType: String, Codable, CaseIterable, Identifiable {
    case shell
    case python

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .shell: return "Shell Script".localized
        case .python: return "Python Script".localized
        }
    }
}

/// 代码片段分类。
struct CodeSnippetCategory: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
}

/// 代码片段。
struct CodeSnippet: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var type: CodeSnippetType
    var content: String
    var categoryID: UUID

    var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !content.isEmpty
    }
}

/// 管理代码片段与分类的持久化存储。
final class CodeSnippetStore: ObservableObject {
    static let shared = CodeSnippetStore()

    @Published var categories: [CodeSnippetCategory] = []
    @Published var snippets: [CodeSnippet] = []

    private let categoriesKey = "ghostty_code_snippet_categories"
    private let snippetsKey = "ghostty_code_snippets"

    private init() {
        load()
        ensureDefaultCategory()
    }

    var defaultCategory: CodeSnippetCategory {
        categories.first { $0.name == "Default".localized } ?? CodeSnippetCategory(name: "Default".localized)
    }

    // MARK: - 分类 CRUD

    func addCategory(_ category: CodeSnippetCategory) {
        categories.append(category)
        save()
    }

    func updateCategory(_ category: CodeSnippetCategory) {
        guard let index = categories.firstIndex(where: { $0.id == category.id }) else { return }
        categories[index] = category
        save()
    }

    func removeCategory(_ id: UUID) {
        guard id != defaultCategory.id else { return }
        categories.removeAll { $0.id == id }
        for index in snippets.indices where snippets[index].categoryID == id {
            snippets[index].categoryID = defaultCategory.id
        }
        save()
    }

    // MARK: - 代码片段 CRUD

    func addSnippet(_ snippet: CodeSnippet) {
        snippets.append(snippet)
        save()
    }

    func updateSnippet(_ snippet: CodeSnippet) {
        guard let index = snippets.firstIndex(where: { $0.id == snippet.id }) else { return }
        snippets[index] = snippet
        save()
    }

    func removeSnippet(_ id: UUID) {
        snippets.removeAll { $0.id == id }
        save()
    }

    func snippets(for categoryID: UUID) -> [CodeSnippet] {
        snippets.filter { $0.categoryID == categoryID }
    }

    // MARK: - 持久化

    private func save() {
        if let data = try? JSONEncoder().encode(categories) {
            UserDefaults.standard.set(data, forKey: categoriesKey)
        }
        if let data = try? JSONEncoder().encode(snippets) {
            UserDefaults.standard.set(data, forKey: snippetsKey)
        }
        UserDefaults.standard.synchronize()
    }

    private func load() {
        if let data = UserDefaults.standard.data(forKey: categoriesKey),
           let loaded = try? JSONDecoder().decode([CodeSnippetCategory].self, from: data) {
            categories = loaded
        }
        if let data = UserDefaults.standard.data(forKey: snippetsKey),
           let loaded = try? JSONDecoder().decode([CodeSnippet].self, from: data) {
            snippets = loaded
        }
    }

    private func ensureDefaultCategory() {
        if !categories.contains(where: { $0.name == "Default".localized }) {
            categories.insert(CodeSnippetCategory(name: "Default".localized), at: 0)
            save()
        }
    }
}
