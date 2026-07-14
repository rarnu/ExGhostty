import Foundation
import SwiftUI
import Combine

/// 管理 SSH 连接和分组的存储，带 UserDefaults 持久化
class SSHStore: ObservableObject {
    // MARK: - Published 属性

    @Published var connections: [SSHConnection] = []
    @Published var groups: [SSHGroup] = []
    @Published var searchText: String = ""

    // MARK: - 单例

    static let shared = SSHStore()

    private let connectionsKey = "ghostty_ssh_connections"
    private let groupsKey = "ghostty_ssh_groups"

    private init() {
        load()
    }

    // MARK: - 查询

    var filteredConnections: [SSHConnection] {
        if searchText.isEmpty { return connections }
        return connections.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    func connections(for groupID: UUID) -> [SSHConnection] {
        connections.filter { $0.groupID == groupID }
    }

    var ungroupedConnections: [SSHConnection] {
        connections.filter { $0.groupID == nil }
    }

    // MARK: - CRUD 连接

    func addConnection(_ conn: SSHConnection) {
        connections.append(conn)
        save()
    }

    func removeConnection(_ id: UUID) {
        connections.removeAll { $0.id == id }
        save()
    }

    func updateConnection(_ conn: SSHConnection) {
        guard let i = connections.firstIndex(where: { $0.id == conn.id }) else { return }
        connections[i] = conn
        save()
    }

    // MARK: - CRUD 分组

    func addGroup(_ group: SSHGroup) {
        groups.append(group)
        save()
    }

    func removeGroup(_ id: UUID) {
        groups.removeAll { $0.id == id }
        for i in connections.indices where connections[i].groupID == id {
            connections[i].groupID = nil
        }
        // 显式通知数组变化（上面的属性赋值不会触发 didSet）
        objectWillChange.send()
        save()
    }

    func updateGroup(_ group: SSHGroup) {
        guard let i = groups.firstIndex(where: { $0.id == group.id }) else { return }
        groups[i] = group
        save()
    }

    // MARK: - 持久化

    private func save() {
        if let connData = try? JSONEncoder().encode(connections) {
            UserDefaults.standard.set(connData, forKey: connectionsKey)
        }
        if let groupData = try? JSONEncoder().encode(groups) {
            UserDefaults.standard.set(groupData, forKey: groupsKey)
        }
        UserDefaults.standard.synchronize()
    }

    private func load() {
        if let connData = UserDefaults.standard.data(forKey: connectionsKey),
           let conns = try? JSONDecoder().decode([SSHConnection].self, from: connData) {
            connections = conns
        }
        if let groupData = UserDefaults.standard.data(forKey: groupsKey),
           let gs = try? JSONDecoder().decode([SSHGroup].self, from: groupData) {
            groups = gs
        }
    }
}
