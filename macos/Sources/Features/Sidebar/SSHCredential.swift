import Foundation
import SwiftUI
import Combine

/// SSH 凭证（账号/密码对）
struct SSHCredential: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var username: String
    var password: String

    init(
        id: UUID = UUID(),
        name: String,
        username: String,
        password: String
    ) {
        self.id = id
        self.name = name
        self.username = username
        self.password = password
    }
}

/// 凭证存储（简单 UserDefaults 持久化，生产环境建议换 Keychain）
class SSHCredentialStore: ObservableObject {
    @Published var credentials: [SSHCredential] = []

    static let shared = SSHCredentialStore()

    private let key = "ghostty_ssh_credentials"

    private init() {
        load()
    }

    func add(_ credential: SSHCredential) {
        credentials.append(credential)
        save()
    }

    func update(_ credential: SSHCredential) {
        guard let i = credentials.firstIndex(where: { $0.id == credential.id }) else { return }
        credentials[i] = credential
        save()
    }

    func remove(_ id: UUID) {
        credentials.removeAll { $0.id == id }
        save()
    }

    func credential(id: UUID?) -> SSHCredential? {
        guard let id else { return nil }
        return credentials.first { $0.id == id }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(credentials) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private func load() {
        if let data = UserDefaults.standard.data(forKey: key),
           let list = try? JSONDecoder().decode([SSHCredential].self, from: data) {
            credentials = list
        }
    }
}
