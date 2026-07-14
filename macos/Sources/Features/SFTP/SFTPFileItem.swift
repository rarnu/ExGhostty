import Foundation

/// 远程文件/目录项。
struct SFTPFileItem: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let type: SFTPItemType
    let size: Int64?
    let modificationDate: Date?
    let permissions: String?

    /// 是否为目录。
    var isDirectory: Bool { type == .directory }

    /// 是否为隐藏文件/目录。
    var isHidden: Bool { name.hasPrefix(".") }
}

enum SFTPItemType {
    case file
    case directory
    case symlink
    case other
}
