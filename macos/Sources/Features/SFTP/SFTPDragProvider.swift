import Foundation
import Combine
import UniformTypeIdentifiers

/// SFTP 列表条目的拖拽提供者。
///
/// - 进程内携带文件名文本载荷，用于列表内部"拖拽移动到子目录"。
/// - 拖出到 Finder 时，接收方请求文件载荷后才把条目下载到临时目录
///   （每个条目生成一个正常的下载任务），再把临时文件交给系统复制到拖放目标目录。
///
/// 注：macOS 26+ 起 NSFilePromiseProvider 不再继承 NSItemProvider，
/// 无法再从 SwiftUI `.onDrag` 直接提供 file promise，因此采用
/// `registerFileRepresentation` 的"先下载到临时目录再交付"方案。
final class SFTPDragProvider: NSItemProvider {
    /// - Parameters:
    ///   - draggedItem: 被拖拽的那一行条目，用于进程内移动载荷。
    ///   - items: 实际参与拖出下载的条目集合（多选时为整个选中集合）。
    init(
        draggedItem: SFTPFileItem,
        items: [SFTPFileItem],
        connection: SSHConnection,
        remoteDirectory: String
    ) {
        super.init()

        // 进程内载荷：列表内部拖拽移动到子目录时使用，外部 App 不可见。
        let nameData = Data(draggedItem.name.utf8)
        registerDataRepresentation(
            forTypeIdentifier: UTType.plainText.identifier,
            visibility: .ownProcess
        ) { completion in
            completion(nameData, nil)
            return nil
        }

        // 拖出载荷：接收方（如 Finder）请求时才触发下载。
        let isFolder = items.count > 1 || (items.first?.isDirectory ?? false)
        suggestedName = items.count == 1 ? items[0].name : "\(items.count) items"
        registerFileRepresentation(
            forTypeIdentifier: isFolder ? UTType.folder.identifier : UTType.data.identifier,
            fileOptions: [],
            visibility: .all
        ) { completion in
            Task {
                do {
                    let url = try await Self.downloadToTemporary(
                        items: items,
                        connection: connection,
                        remoteDirectory: remoteDirectory
                    )
                    completion(url, false, nil)
                } catch {
                    completion(nil, false, error)
                }
            }
            return nil
        }
    }

    /// 把条目逐个下载到临时目录（每个条目生成一个下载任务，在任务列表中可见），
    /// 完成后返回要交给接收方的 URL：单条目为该文件/目录本身，多条目为包含全部条目的目录。
    private static func downloadToTemporary(
        items: [SFTPFileItem],
        connection: SSHConnection,
        remoteDirectory: String
    ) async throws -> URL {
        let displayName = items.count == 1 ? items[0].name : "\(items.count) items"
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghostty_sftp_drag_\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(displayName, isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

        for item in items {
            let task = SFTPTask(
                type: .download,
                localPath: staging.path,
                remotePath: remoteDirectory + "/" + item.name,
                title: item.name,
                connection: connection,
                isDirectory: item.isDirectory,
                fileSize: item.size
            )
            SFTPTransferManager.shared.addTask(task)
            try await waitForCompletion(of: task)
        }

        return items.count == 1 ? staging.appendingPathComponent(items[0].name) : staging
    }

    /// 等待下载任务结束，失败或被取消时抛出错误。
    private static func waitForCompletion(of task: SFTPTask) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var cancellable: AnyCancellable?
            cancellable = task.$state
                .receive(on: DispatchQueue.main)
                .sink { state in
                    switch state {
                    case .completed:
                        cancellable?.cancel()
                        continuation.resume()
                    case .failed, .cancelled:
                        cancellable?.cancel()
                        continuation.resume(throwing: SFTPError.transferFailed(
                            task.errorMessage ?? "Download cancelled".localized
                        ))
                    default:
                        break
                    }
                }
        }
    }
}
