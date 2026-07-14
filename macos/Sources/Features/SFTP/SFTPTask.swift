import Foundation
import Combine

/// 传输方向。
enum SFTPTaskType: String, CaseIterable {
    case upload
    case download
}

/// 任务状态。
enum SFTPTaskState: String, CaseIterable {
    case pending
    case running
    case paused
    case completed
    case failed
    case cancelled
}

/// 单个 SFTP 上传/下载任务。
final class SFTPTask: ObservableObject, Identifiable {
    let id = UUID()
    let type: SFTPTaskType
    /// 本地路径（上传源或下载目标）。
    let localPath: String
    /// 远程路径（上传目标或下载源）。
    let remotePath: String
    /// 任务标题（文件名或目录名）。
    let title: String
    /// 关联的 SSH 连接。
    let connection: SSHConnection
    /// 是否为目录（下载目录/上传目录时使用）。
    let isDirectory: Bool

    @Published var state: SFTPTaskState = .pending
    @Published var progress: Double = 0
    @Published var errorMessage: String?

    /// 当前正在执行该任务的进程，用于暂停/取消。
    weak var process: Process?

    init(
        type: SFTPTaskType,
        localPath: String,
        remotePath: String,
        title: String,
        connection: SSHConnection,
        isDirectory: Bool = false
    ) {
        self.type = type
        self.localPath = localPath
        self.remotePath = remotePath
        self.title = title
        self.connection = connection
        self.isDirectory = isDirectory
    }

    var isActive: Bool {
        state == .pending || state == .running || state == .paused
    }

    var isCompleted: Bool {
        state == .completed || state == .failed || state == .cancelled
    }
}
