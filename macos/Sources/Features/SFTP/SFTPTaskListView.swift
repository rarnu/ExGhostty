import AppKit
import SwiftUI
import Combine

/// SFTP 传输任务列表窗口内容。
struct SFTPTaskListView: View {
    @StateObject private var manager = SFTPTransferManager.shared
    let connection: SSHConnection?

    private var displayedTasks: [SFTPTask] {
        guard let connection else { return manager.tasks }
        return manager.tasks.filter { $0.connection.id == connection.id }
    }

    var body: some View {
        VStack(spacing: 0) {
            taskList
            bottomToolbar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var taskList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if displayedTasks.isEmpty {
                    Text("暂无传输任务")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                        .padding(.top, 60)
                } else {
                    ForEach(displayedTasks) { task in
                        SFTPTaskRow(task: task)
                            .frame(maxWidth: .infinity)
                        Divider()
                    }
                }
            }
        }
    }

    private var bottomToolbar: some View {
        HStack {
            Spacer()
            Button("清空全部") {
                manager.clearCompleted(for: connection)
            }
            .font(.system(size: 12))
            .buttonStyle(.plain)
            .foregroundColor(.accentColor)
            .disabled(displayedTasks.allSatisfy { !$0.isCompleted })
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(Color(.controlBackgroundColor).opacity(0.15))
    }
}

/// 单个任务行。
private struct SFTPTaskRow: View {
    @ObservedObject var task: SFTPTask

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            directionIcon
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 4) {
                // 第一行：文件名、操作按钮，文件大小右对齐
                HStack(spacing: 8) {
                    Text(task.title)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)

                    Spacer()

                    if let size = task.fileSize {
                        Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }

                    actionButtons
                }

                // 第二行：目标路径
                Text(destinationPath)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .textSelection(.enabled)

                // 第三行：进度条与状态
                HStack(spacing: 10) {
                    ProgressView(value: task.progress)
                        .progressViewStyle(.linear)
                        .frame(maxWidth: .infinity)
                    Text(statusText)
                        .font(.system(size: 11))
                        .foregroundColor(statusColor)
                        .lineLimit(1)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var directionIcon: some View {
        let icon = task.type == .upload ? "arrow.up" : "arrow.down"
        Image(systemName: icon)
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(task.type == .upload ? .orange : .accentColor)
    }

    @ViewBuilder
    private var actionButtons: some View {
        HStack(spacing: 6) {
            if task.state == .failed, let error = task.errorMessage {
                Button(action: {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(error, forType: .string)
                }) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .help("复制错误信息")
            }

            switch task.state {
            case .running:
                Button(action: { SFTPTransferManager.shared.pauseTask(task) }) {
                    Image(systemName: "pause.fill")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .help("暂停")
            case .paused:
                Button(action: { SFTPTransferManager.shared.resumeTask(task) }) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .help("恢复")
            default:
                EmptyView()
            }

            Button(action: { SFTPTransferManager.shared.cancelTask(task) }) {
                Image(systemName: "xmark")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .help("删除")
        }
        .foregroundColor(.secondary)
    }

    /// 目标路径：上传显示远程目录，下载显示本地保存目录。
    private var destinationPath: String {
        switch task.type {
        case .upload:
            return task.remotePath
        case .download:
            return task.localPath
        }
    }

    private var statusText: String {
        switch task.state {
        case .pending:   return "等待中"
        case .running:   return String(format: "%.0f%%", task.progress * 100)
        case .paused:    return "已暂停"
        case .completed: return "已完成"
        case .failed:    return task.errorMessage ?? "失败"
        case .cancelled: return "已取消"
        }
    }

    private var statusColor: Color {
        switch task.state {
        case .failed:    return .red
        case .completed: return .green
        default:         return .secondary
        }
    }
}
