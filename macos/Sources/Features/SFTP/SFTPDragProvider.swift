import AppKit
import UniformTypeIdentifiers

/// SFTP 列表条目的 AppKit 拖拽会话。
///
/// SwiftUI `.onDrag` 只能返回单个 NSItemProvider，一次拖拽最多交付一个文件；
/// 而 macOS 26+ 起 NSFilePromiseProvider 改为 NSPasteboardWriting，
/// 可以通过 NSDraggingItem 在 AppKit 拖拽会话中为每个选中条目各提供一个
/// file promise，从而把多选条目作为独立的 N 个文件/目录拖入 Finder。
enum SFTPDragSession {
    /// 列表内部"拖拽移动到子目录"使用的自定义拖拽类型（对外部 App 无意义，会被忽略）。
    static let internalMoveType = NSPasteboard.PasteboardType("com.exghostty.sftp-move")
    /// 与 internalMoveType 对应的 UTType，用于 SwiftUI onDrop。
    static let internalMoveUTType = UTType(exportedAs: "com.exghostty.sftp-move")

    /// 是否已有拖拽会话在进行中（SwiftUI 手势会多次回调，用于去重）。
    private static var isActive = false
    /// 强引用当前会话的 source，保证回调期间不被释放。
    private static var activeSource: SFTPDraggingSource?

    /// 从列表行启动拖拽会话。
    ///
    /// - Parameters:
    ///   - draggedItem: 被拖拽的那一行条目，用于进程内移动载荷。
    ///   - items: 实际参与拖出的条目集合（多选时为整个选中集合）。
    static func begin(
        draggedItem: SFTPFileItem,
        items: [SFTPFileItem],
        connection: SSHConnection,
        remoteDirectory: String,
        event: NSEvent,
        view: NSView
    ) {
        guard !isActive, !items.isEmpty else { return }
        isActive = true

        let location = view.convert(event.locationInWindow, from: nil)
        let isMulti = items.count > 1
        let symbolName = isMulti ? "doc.on.doc" : (items[0].isDirectory ? "folder" : "doc")
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 24, weight: .regular)) ?? NSImage()

        // 每个条目一个 file promise：拖入 Finder 后各自落地为独立的文件/目录。
        var draggingItems: [NSDraggingItem] = items.enumerated().map { index, item in
            let provider = SFTPFilePromiseProvider(item: item, connection: connection, remoteDirectory: remoteDirectory)
            let draggingItem = NSDraggingItem(pasteboardWriter: provider)
            // 多条目时略微错开，形成堆叠效果。
            let frame = CGRect(
                x: location.x - 16 + CGFloat(index * 4),
                y: location.y - 16 - CGFloat(index * 4),
                width: 32,
                height: 32
            )
            draggingItem.setDraggingFrame(frame, contents: image)
            return draggingItem
        }

        // 进程内移动载荷：携带被拖拽行的条目名，目录行的 onDrop 凭此执行 mv。
        // 该 dragging item 不产生拖拽图像。
        let internalItem = NSPasteboardItem()
        internalItem.setData(Data(draggedItem.name.utf8), forType: internalMoveType)
        let internalDraggingItem = NSDraggingItem(pasteboardWriter: internalItem)
        internalDraggingItem.draggingFrame = CGRect(x: location.x, y: location.y, width: 1, height: 1)
        internalDraggingItem.imageComponentsProvider = { [] }
        draggingItems.append(internalDraggingItem)

        let source = SFTPDraggingSource {
            isActive = false
            activeSource = nil
        }
        activeSource = source
        view.beginDraggingSession(with: draggingItems, event: event, source: source)
    }
}

/// 拖拽会话源：提供拖拽操作类型，并在会话结束时复位状态。
private final class SFTPDraggingSource: NSObject, NSDraggingSource {
    private let onEnd: () -> Void

    init(onEnd: @escaping () -> Void) {
        self.onEnd = onEnd
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        return context == .withinApplication ? [.move, .copy] : [.copy]
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        onEnd()
    }
}

/// 单个条目的 file promise。
///
/// Finder 等接收方在拖放后请求写入时，以目标目录为下载目录生成一个下载任务，
/// 任务完成后文件即出现在拖放目标目录（与面板内的下载行为一致）。
final class SFTPFilePromiseProvider: NSFilePromiseProvider, NSFilePromiseProviderDelegate {
    private let item: SFTPFileItem
    private let connection: SSHConnection
    /// 条目所在的远程目录（即列表当前目录）。
    private let remoteDirectory: String

    init(item: SFTPFileItem, connection: SSHConnection, remoteDirectory: String) {
        self.item = item
        self.connection = connection
        self.remoteDirectory = remoteDirectory
        super.init()
        self.fileType = item.isDirectory ? UTType.folder.identifier : UTType.data.identifier
        self.delegate = self
    }

    // MARK: - NSFilePromiseProviderDelegate

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        return item.name
    }

    func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider,
        writePromiseTo url: URL,
        completionHandler: @escaping (Error?) -> Void
    ) {
        // 文件不在这里直接写入：生成下载任务（任务列表中可见、可管理），
        // 目标目录就是 Finder 指定的落点，任务完成后文件即出现在该目录。
        let task = SFTPTask(
            type: .download,
            localPath: url.deletingLastPathComponent().path,
            remotePath: remoteDirectory + "/" + item.name,
            title: item.name,
            connection: connection,
            isDirectory: item.isDirectory,
            fileSize: item.size
        )
        SFTPTransferManager.shared.addTask(task)
        completionHandler(nil)
    }
}
