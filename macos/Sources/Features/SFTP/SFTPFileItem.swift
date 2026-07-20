import Foundation
import UniformTypeIdentifiers

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

    /// 是否为文本文件（用于双击/右键使用 fresh 编辑）。
    /// 通过扩展名排除常见二进制格式；无扩展名或未知扩展名默认视为文本。
    var isTextFile: Bool {
        guard type == .file else { return false }
        let ext = (name as NSString).pathExtension.lowercased()
        let binaryExtensions: Set<String> = [
            "png", "jpg", "jpeg", "gif", "bmp", "tiff", "webp", "ico", "heic", "heif",
            "mp3", "mp4", "mov", "avi", "mkv", "flv", "wmv", "webm",
            "zip", "tar", "gz", "bz2", "xz", "rar", "7z", "dmg", "iso", "pkg", "deb", "rpm",
            "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx",
            "exe", "dll", "so", "dylib", "app", "bin", "o", "a"
        ]
        return !binaryExtensions.contains(ext)
    }

    /// 是否为图片文件（用于双击用 Preview 预览）。
    /// 通过 UTType（mimetype）判断，覆盖常见图片格式。
    var isImageFile: Bool {
        guard type == .file else { return false }
        let ext = (name as NSString).pathExtension
        guard let utType = UTType(filenameExtension: ext) else { return false }
        return utType.conforms(to: .image)
    }
}

enum SFTPItemType {
    case file
    case directory
    case symlink
    case other
}
